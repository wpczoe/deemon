CREATE TABLE CSRF_tests_results (
       id               integer,
       seq_id           integer,
       time             character varying,
       projname         character varying,
       session          character varying,
       operation        character varying,
       user             character varying,
       uuid_request     character varying,
       uuid_tn          character varying,
       uuid_src_var     character varying,
       uuid_sink_var    character varying,
       method           character varying,
       url              character varying,
       headers          character varying,
       body             character varying,
       query_message    character varying, 
       query_hash       character varying, 
       apt_uuid         character varying, 
       observed         character varying, 
       tr_pattern       character varying,
       PRIMARY KEY (id)
);