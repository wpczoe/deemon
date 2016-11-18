#|
Author:Simon Koch <s9sikoch@stud.uni-saarland.de>
This file is (as the name suggests) the main file. It parses
the passed cmd arguments and starts the whole service and
waits/responds for commands and executes given commands
|#
(in-package :de.uni-saarland.syssec.mosgi)

(defparameter +local-xdebug-buffer+ "/tmp/mosgi-xdebug-buffer")

(opts:define-opts
  (:name :php-session-folder
	 :description "absolute path on the guest system to the folder where the relevant php-sessions are stored (default:/opt/bitnami/php/tmp/)"
	 :short #\P
	 :long "php-session-folder"
	 :arg-parser #'identity)
  (:name :xdebug-trace-file
	 :description "absolute path to the file containing machine readable trace generated by xdebug on the guest system (default:/tmp/xdebug.xt)"
	 :short #\x
	 :long "xdebug-trace-file"
	 :arg-parser #'identity)
  (:name :port
	 :description "the port mosgi shall listen on for a command connection (default:8844)"
	 :short #\p
	 :long "port"
	 :arg-parser #'parse-integer)
  (:name :interface
	 :description "the ip-address mosgi shall listen on for a command connection (default:127.0.0.1)"
	 :short #\i
	 :long "interface"
	 :arg-parser #'identity)
  (:name :target-system-ip
	 :description "the ip-address of the guest system to connect to via ssh - sshd needs to be running"
	 :short #\t
	 :long "target-system"
	 :arg-parser #'identity)
  (:name :target-system-root
	 :description "the root user of the guest system (default:root)"
	 :short #\r
	 :long "target-root"
	 :arg-parser #'identity)
  (:name :target-system-pwd
	 :description "the password for the root account of the guest system (default:bitnami)"
	 :short #\c
	 :long "host-pwd"
	 :arg-parser #'identity)
  (:name :sql-db-path
	 :description "the file path to the sqlite db"
	 :short #\s
	 :long "sql-db-path"
	 :arg-parser #'identity))


(defparameter *legal-communication-bytes*
  '((0 . :START-DIFF) 
    (1 . :KILL-YOURSELF) 
    (2 . :FINISHED-DIFF)
    (42 . :STREAM-EOF)))


(defparameter *listen-port* 4242)

(defparameter *target-ip*  "127.0.0.1")

(defparameter *task-mutex* (sb-thread:make-mutex :name "task mutex"))

(defparameter *task-waitqueue* (sb-thread:make-waitqueue :name "task waitqueue"))

(defparameter *request-queue* (sb-concurrency:make-queue :name "request queue"))

(defparameter *stop-p* nil)

(defparameter *print-mutex* (sb-thread:make-mutex :name "print mutex"))

(defparameter *to-print-to* *standard-output*)


(defun print-threaded (thread-name string)
  (sb-thread:with-mutex (*print-mutex*)
    (FORMAT *to-print-to* "[~a] : ~a~%" thread-name string)))


(defun save-relevant-files (php-session-folder xdebug-trace-file user host pwd request-db-id)
  (handler-case
      (handler-bind ((error #'(lambda (err)
                                (print-threaded :mover (FORMAT nil "unhandled error ~a~%~a" 
                                                               err
                                                               (with-output-to-string (stream)
                                                                 (sb-debug:print-backtrace :stream stream))))
                                (error err))))
        (progn	
          (ssh-interface:backup-all-files-from php-session-folder (FORMAT nil "/tmp/php-sessions-~a/" request-db-id) user host pwd #'(lambda(string)
                                                                                                                                       (print-threaded :mover string)))
          (ssh-interface:move-file xdebug-trace-file (FORMAT nil "/tmp/xdebug-trace-~a/" request-db-id) user host pwd #'(lambda(string)
                                                                                                                            (print-threaded :mover string)))
          (print-threaded :mover (FORMAT nil "backed up ~a" php-session-folder))
          (print-threaded :mover (FORMAT nil "backed up ~a" xdebug-trace-file))
          (sb-thread:with-mutex (*task-mutex*)	  
            (sb-concurrency:enqueue request-db-id *request-queue*)
            (sb-thread:condition-broadcast *task-waitqueue*)
            (print-threaded :mover (FORMAT nil "save and added request ~a to the work queue" request-db-id)))))
    (error (e)
      (declare (ignore e)))))
	    

(defun create-mover-thread (php-session-folder xdebug-trace-folder user host pwd interface port)
  (sb-thread:make-thread #'(lambda()
			     (unwind-protect 
				  (handler-case 
				      (com:with-connected-communication-handler (handler interface port)
					(print-threaded :mover "connection established")
					(do ((received-order (com:receive-byte handler)
							     (com:receive-byte handler))
					     (com-broken-p nil))
					    ((or com-broken-p
						 (= (car (find :KILL-YOURSELF *legal-communication-bytes* :key #'cdr)) received-order)) nil)
					  (print-threaded :mover (FORMAT nil "Received Command: ~a" (cdr (find received-order *legal-communication-bytes* :key #'car))))
					  (ecase (cdr (find received-order *legal-communication-bytes* :key #'car))
					    (:START-DIFF 		 
					     (save-relevant-files php-session-folder xdebug-trace-folder user host pwd (com:receive-32b-unsigned-integer handler))
					     (com:send-byte handler (car (find :FINISHED-DIFF *legal-communication-bytes* :key #'cdr)))
					     (print-threaded :mover "Finished backup - send FINISHED-DIFF - waiting for next command"))					
					    (:STREAM-EOF
					     (setf com-broken-p T)
					     (print-threaded :mover "connection closed from remote end")))))
				    (error (e)
				      (print-threaded :mover (FORMAT nil "encountered fatal error ~a" e))))
			       (print-threaded :mover "I am done")))
			 :name "mover"))


(defun transfer-relevant-files (database-path request-db-id user host pwd)
  (let ((xdebug-trace-file (FORMAT nil "/tmp/xdebug-trace-~a/xdebug.xt" request-db-id))
	(php-session-folder (FORMAT nil "/tmp/php-sessions-~a/" request-db-id)))
    (handler-case 
	(clsql:with-database (database-connection (list database-path) :database-type :sqlite3)
	  (print-threaded :saver (FORMAT nil "copy php sessions for request ~a onto host" request-db-id))	  
	  (database:enter-sessions-raw-into-db 
           (ssh-interface:get-all-contained-files-as-base64-blob php-session-folder user host pwd #'(lambda(string)
                                                                                                      (print-threaded :saver string)))
           request-db-id
           database-connection 
           #'(lambda(string)
               (print-threaded :saver string)))
	  (ssh-interface:delete-folder php-session-folder user host pwd)
	  (print-threaded :saver (FORMAT nil "copy xdebug dump for request ~a onto host" request-db-id))
          (if (= (length (ssh-interface:folder-content-guest (FORMAT nil "/tmp/xdebug-trace-~a/" request-db-id)
                                                             user host pwd))
                 0)
              (print-threaded :saver (FORMAT nil "no xdebug dump found"))
              (let ((xdebug-file-path (ssh-interface:get-file-as-file 
                                       xdebug-trace-file 
                                       +local-xdebug-buffer+
                                       #'(lambda(string)
                                           (print-threaded :saver string)))))
                (sb-ext:gc :full t)
                (database:enter-xdebug-file-into-db xdebug-file-path
                                                    request-db-id
                                                    database-connection 
                                                    #'(lambda(string)
                                                        (print-threaded :saver string)))
                (sb-ext:gc :full t)))
          (ssh-interface:delete-folder (FORMAT nil "/tmp/xdebug-trace-~a/" request-db-id) user host pwd))
      (error (e)
	(print-threaded :saver (FORMAT nil "ERROR ~a" e))))))


(defun create-saver-thread (user host pwd sqlite-db-path)
  (sb-thread:make-thread #'(lambda()
			     (unwind-protect 
				  (tagbody
				   check
				     (sb-thread:with-mutex (*task-mutex*)
				       (cond 
                                         ((and *stop-p*
                                               (sb-concurrency:queue-empty-p *request-queue*))
                                          (go end))
                                         ((not *stop-p*)
                                          (sb-thread:condition-wait *task-waitqueue* *task-mutex*)
                                          (go check))
                                         (t
                                          (go work))))
				   work
				     (transfer-relevant-files sqlite-db-path (sb-concurrency:dequeue *request-queue*) user host pwd)
				     (print-threaded :saver (FORMAT nil "~a requests for processing remaining" (sb-concurrency:queue-count *request-queue*)))
				     (go check)
				   end))
			     (print-threaded :saver "I am done"))
			 :name "savior"))
	  	     
       
(defmacro aif (condition then &optional else)
  `(let ((it ,condition))
     (if it
	 ,then
	 ,else)))


(defun main ()
  (handler-case
      (multiple-value-bind (options free-args)
	  (opts:get-opts)
	(declare (ignore free-args))
	(setf *stop-p* nil)
	(FORMAT T "Congratulation you started mosgi - a program which will most likely:~%")
	(FORMAT T "- crash your computer~%")
	(FORMAT T "Furthermore it will do/use:~%")
	(FORMAT T "listen on ~a:~a~%" (aif (getf options :interface) it "127.0.0.1") (aif (getf options :port) it 8844))
	(FORMAT T "target ssh ~a@~a using password ~a~%" 
		(aif (getf options :target-system-root) it "root") 
		(getf options :target-system-ip) 
		(aif (getf options :target-system-pwd) it "bitnami"))
	(FORMAT T "xdebug-trace-folder: ~a~%" (aif (getf options :xdebug-trace-file) it "/tmp/xdebug.xt"))
	(FORMAT T "php-session-folder: ~a~%" (aif (getf options :php-session-folder) it "/opt/bitnami/php/tmp/"))
        (ssh-interface:with-active-ssh-connection ((getf options :target-system-root)
                                                   (getf options :target-system-ip)
                                                   (getf options :target-system-pwd))
          (FORMAT T "scanning /tmp/:~%~a~%"
                  (ssh-interface:folder-content-guest "/tmp/" 
                                                      (getf options :target-system-root)
                                                      (getf options :target-system-ip)
                                                      (getf options :target-system-pwd)))
          (ssh-interface:run-remote-shell-command "rm -f /tmp/*.xt" 
                                                  (getf options :target-system-root)
                                                  (getf options :target-system-ip)
                                                  (getf options :target-system-pwd)
                                                  #'(lambda (discard)
                                                      (declare (ignore discard))))
          (let ((differ-thread (create-saver-thread  (aif (getf options :target-system-root) it "root")
                                                     (aif (getf options :target-system-ip) it (error "you need to provide the target system ip"))
                                                     (aif (getf options :target-system-pwd) it "bitnami")
                                                     (aif (getf options :sql-db-path) it (error "you need to provide the sqlite db path"))))
                (mover-thread (create-mover-thread (aif (getf options :php-session-folder) it "/opt/bitnami/php/tmp")
                                                   (aif (getf options :xdebug-trace-file) it "/tmp/xdebug.xt")
                                                   (aif (getf options :target-system-root) it "root")
                                                   (aif (getf options :target-system-ip) it (error "you need to provide the target system ip"))
                                                   (aif (getf options :target-system-pwd) it "bitnami")
                                                   (aif (getf options :interface) it "127.0.0.1")
                                                   (aif (getf options :port) it 8844))))
            (unwind-protect
                 (progn 
                   #|(ssh-interface:register-machine (aif (getf options :target-system-root) it "root")
                   (aif (getf options :target-system-ip) it (error "you need to provide the target system ip"))
                   (aif (getf options :target-system-pwd) it "bitnami"))|#
                   (handler-case
                       (progn 
                         (print-threaded :main (FORMAT nil "Started threads Differ [~a] / Mover [~a]" (sb-thread:thread-alive-p differ-thread) (sb-thread:thread-alive-p mover-thread)))
                         (sb-thread:join-thread mover-thread)
                         (print-threaded :main "Mover thread done"))
                     (sb-thread:thread-error (e)
                       (print-threaded :main (FORMAT nil "Error in thread mover ~a" e)))))
              (sb-thread:with-mutex (*task-mutex*)
                (setf *stop-p* T)
                (sb-thread:condition-broadcast *task-waitqueue*))
              (sb-thread:join-thread differ-thread)))))
    (unix-opts:unknown-option (err)
      (declare (ignore err))
      (opts:describe
       :prefix "This program is the badass doing all the work to differentiate state changes after actions on webapplications - kneel before thy master"
       :suffix "so that's how it works…"
       :usage-of "run.sh"))))
