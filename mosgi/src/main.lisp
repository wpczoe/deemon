#|
Author:Simon Koch <s9sikoch@stud.uni-saarland.de>
This file is (as the name suggests) the main file. It parses
the passed cmd arguments and starts the whole service and
waits/responds for commands and executes given commands
|#
(in-package :de.uni-saarland.syssec.mosgi)

(opts:define-opts
  (:name :php-session-folder
	 :description "absolute path on the guest system to the folder where the relevant php-sessions are stored"
	 :short #\P
	 :long "php-session-folder"
	 :arg-parser #'identity)
  (:name :xdebug-trace-file
	 :description "absolute path to the file containing machine readable trace generated by xdebug on the guest system"
	 :short #\x
	 :long "xdebug-trace-file"
	 :arg-parser #'identity)
  (:name :port
	 :description "the port mosgi shall listen on for a command connection"
	 :short #\p
	 :long "port"
	 :arg-parser #'parse-integer)
  (:name :interface
	 :description "the ip-address mosgi shall listen on for a command connection"
	 :short #\i
	 :long "interface"
	 :arg-parser #'identity)
  (:name :target-system-ip
	 :description "the ip-address of the guest system to connect to via ssh - sshd needs to be running"
	 :short #\t
	 :long "target-system"
	 :arg-parser #'identity)
  (:name :target-system-root
	 :description "the root user of the guest system"
	 :short #\r
	 :long "target-root"
	 :arg-parser #'identity)
  (:name :target-system-pwd
	 :description "the password for the root account of the guest system"
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

(defparameter *php-session-diff-state* nil)

(defparameter *file-diff-state* nil) 

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
      (progn
	(print-threaded :mover (FORMAT nil "backed up ~a" php-session-folder))
	(print-threaded :mover (FORMAT nil "backed up ~a" xdebug-trace-file))
	(ssh:backup-all-files-from php-session-folder (FORMAT nil "/tmp/php-sessions-~a/" request-db-id) user host pwd)
	(ssh:backup-file xdebug-trace-file (FORMAT nil "/tmp/xdebug-trace-~a/" request-db-id) user host pwd)
	(sb-thread:with-mutex (*task-mutex*)	  
	  (sb-concurrency:enqueue request-db-id *request-queue*)
	  (sb-thread:condition-broadcast *task-waitqueue*)
	  (print-threaded :mover (FORMAT nil "save and added request ~a to the work queue" request-db-id))))
    (error (e)
      (print-threaded :MOVER (FORMAT nil "ERROR:~a" e)))))
	    

(defun make-diff (user host pwd sqlite-db-path request-db-id)
  (let ((xdebug-trace-folder (FORMAT nil "/tmp/xdebug-trace-~a/" request-db-id))
	(php-session-folder (FORMAT nil "/tmp/php-sessions-~a/" request-db-id)))
    (handler-case
	(progn
	  (print-threaded :differ (FORMAT nil "php session analysis for request ~a" request-db-id))
	  (diff:add-next-state-* *php-session-diff-state* 
				 (diff:make-php-session-history-state php-session-folder user host pwd #'(lambda(string)
													   (print-threaded :differ string))))
	  (ssh:delete-folder php-session-folder user host pwd)
	  (cl-fad:with-open-temporary-file (xdebug-tmp-stream :direction :io :element-type 'character)
	    (print-threaded :differ (FORMAT nil "scp xdebug file for request ~a" request-db-id))
	    (ssh:scp (xdebug:get-xdebug-trace-file (ssh:folder-content-guest xdebug-trace-folder
									     user host pwd))
		     (pathname xdebug-tmp-stream) user host pwd)
	    (finish-output xdebug-tmp-stream)
	    (print-threaded :differ (FORMAT nil "scp'd xdebug file"))
	    (ssh:convert-to-utf8-encoding (namestring (pathname xdebug-tmp-stream))) ;this is just because encoding is stupid
	    (print-threaded :differ (FORMAT nil "parsing xdebug file for request ~a" request-db-id))
	    (let ((xdebug (xdebug:make-xdebug-trace xdebug-tmp-stream)))
	      (diff:add-next-state-* *file-diff-state* 
				     (diff:make-file-history-state 
				      (xdebug:get-changed-files-paths 
				       xdebug)
				      user host pwd))
	      (print-threaded :differ (FORMAT nil "entering xdebug results for request ~a" request-db-id))
	      (clsql:with-database (database (list sqlite-db-path) :database-type :sqlite3)
		(db-interface:commit-sql-queries database request-db-id (xdebug:get-sql-queries xdebug))
		(db-interface:commit-latest-diff database request-db-id *php-session-diff-state*)
		(db-interface:commit-full-sessions database request-db-id (diff:php-sessions (diff:current-state *php-session-diff-state*)))
		(db-interface:commit-latest-diff database request-db-id *file-diff-state*)))
	    (ssh:delete-folder xdebug-trace-folder user host pwd)
	    (print-threaded :differ (FORMAT nil "finished session analysis for request ~a" request-db-id))))
      (error (e)
	(print-threaded :differ (FORMAT nil "ERROR:~a" e))))))


(defun create-differ-thread (user host pwd sqlite-db-path)
  (sb-thread:make-thread #'(lambda()
			     (unwind-protect 
				  (let ((*file-diff-state* (make-instance 'diff:state-trace))
					(*php-session-diff-state* (make-instance 'diff:state-trace)))			       
				    (tagbody
				     check
				       (sb-thread:with-mutex (*task-mutex*)
					 (when *stop-p*
					   (go end))
					 (if (not (sb-concurrency:queue-empty-p *request-queue*))
					     (go work)
					     (sb-thread:condition-wait *task-waitqueue* *task-mutex*))
					 (go check))
				     work
				       (make-diff user host pwd sqlite-db-path (sb-concurrency:dequeue *request-queue*))
				       (print-threaded :differ (FORMAT nil "~a requests for processing remaining" (sb-concurrency:queue-count *request-queue*)))
				       (go check)
				     end))
			       (print-threaded :differ "I am done")))				
			 :name "differ"))
			 

(defun create-mover-thread (php-session-folder xdebug-trace-folder user host pwd interface port)
  (sb-thread:make-thread #'(lambda()
			     (unwind-protect 
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
			       (print-threaded :mover "I am done")))
			 :name "mover"))
	     
       
(defun main ()
  (handler-case
      (multiple-value-bind (options free-args)
	  (opts:get-opts)
	(declare (ignore free-args))
	(setf *stop-p* nil)
	(FORMAT T "Congratulation you started mosgi - a program which will most likely:~%")
	(FORMAT T "- crash your computer~%")
	(FORMAT T "Furthermore it will do/use:~%")
	(FORMAT T "listen on ~a:~a~%" (getf options :interface) (getf options :port))
	(FORMAT T "target ssh ~a@~a using password ~a~%" (getf options :target-system-root) (getf options :target-system-ip) (getf options :target-system-pwd))
	(FORMAT T "xdebug-trace-folder: ~a~%" (getf options :xdebug-trace-file))
	(FORMAT T "php-session-folder: ~a~%" (getf options :php-session-folder))
	(let ((differ-thread (create-differ-thread  (getf options :target-system-root)
						    (getf options :target-system-ip)
						    (getf options :target-system-pwd)
						    (getf options :sql-db-path)))
	      (mover-thread (create-mover-thread (getf options :php-session-folder) 
						 (getf options :xdebug-trace-file)
						 (getf options :target-system-root)
						 (getf options :target-system-ip)
						 (getf options :target-system-pwd)
						 (getf options :interface)
						 (getf options :port))))
	  (ssh:register-machine (getf options :target-system-root)
				(getf options :target-system-ip)
				(getf options :target-system-pwd))
	  (unwind-protect
	       (handler-case
		   (progn 
		     (print-threaded :main (FORMAT nil "Started threads Differ [~a] / Mover [~a]" (sb-thread:thread-alive-p differ-thread) (sb-thread:thread-alive-p mover-thread)))
		     (sb-thread:join-thread mover-thread)
		     (print-threaded :main "Mover thread done"))
		 (sb-thread:thread-error (e)
		   (print-threaded :main (FORMAT nil "Error in thread mover ~a" e))))
	    (sb-thread:with-mutex (*task-mutex*)
	      (setf *stop-p* T)
	      (sb-thread:condition-broadcast *task-waitqueue*))
	    (sb-thread:join-thread differ-thread))))	      
    (unix-opts:unknown-option (err)
      (declare (ignore err))
      (opts:describe
       :prefix "This program is the badass doing all the work to differentiate state changes after actions on webapplications - kneel before thy master"
       :suffix "so that's how it works…"
       :usage-of "run.sh"))))
