;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc.  All rights reserved.
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu)

;;; Core file for accessing Amazon Web Services
(in-module 'aws)

(use-module '{binio})
(use-module '{logger opts texttools webtools gpath regex varconfig})

(define-init %loglevel %notice%)

(define %nosubst '{aws:account aws:region
		   aws:key aws:secret aws:expires
		   aws/refresh aws:token})

(module-export! 
 '{aws:region aws:account aws:key aws:secret
   aws:token aws:expires
   aws/ok? aws/checkok aws/set-creds! aws/creds!
   aws/datesig aws/datesig/head aws/template
   aws/update-creds!
   aws/error})

(define aws:region "us-east-1")
(varconfig! aws:region aws:region)

;;; Templates source
(define template-sources
  (list (dirname (get-component "templates/template.json"))))
(varconfig! aws:templates template-sources #f cons)

;; Default (non-working) values from the environment
(define-init aws:secret
  (and (config 'dotload) (getenv "AWS_SECRET_ACCESS_KEY")))
(define-init aws:key
  (and (config 'dotload) (getenv "AWS_ACCESS_KEY_ID")))
(define-init aws:account
  (and (config 'dotload (getenv "AWS_ACCOUNT_NUMBER"))))

(config-def! 'aws:secret
	     (lambda (var (val))
	       (if (bound? val)
		   (set! aws:secret val)
		   aws:secret)))
(config-def! 'aws:key
	     (lambda (var (val))
	       (if (bound? val)
		   (set! aws:key val)
		   aws:key)))
(config-def! 'aws:account
	     (lambda (var (val))
	       (if (bound? val)
		   (set! aws:account val)
		   aws:account)))

(define-init aws:token #f)
(define-init aws:expires #f)
(define-init aws/refresh #f)

(define key+secret
  #((label key (isxdigit+)) "#" (label secret (isxdigit+) ->secret)))

(define-init aws:config #[])

(define cred-fields #(aws:key aws:secret aws:region aws:account))

(define (handle-creds string (fields cred-fields))
  (if (exists? (text->frame key+secret string))
      (let ((match (text->frame key+secret string)))
	(store! aws:config 'aws:key (get match 'key))
	(store! aws:config 'aws:secret (get match 'secret)))
      (doseq (config (remove "" (map trim-spaces (textslice string '(+ {(isspace) ";"}) #f)))
		     i)
	(let ((var (if (position #\= config)
		       (decode-entities (slice config 0 (position #\= config)))
		       (and (< i (length fields)) (elt fields i))))
	      (val (if (position #\= config)
		       (slice config (1+ (position #\= config)))
		       config)))
	  (if (has-prefix val "#")
	      (set! val (->secret (decode-entities (slice val 1))))
	      (set! val (decode-entities val)))
	  (config! var val)
	  (when (and (string? var) (has-prefix var "AWS:"))
	    (store! aws:config (string->symbol (slice var 4))
		    val))))))
  
;;; Other config info

(define (set-aws-config val)
  (cond ((and (symbol? val) (config val))
	 (set-aws-config (config val)))
	((and (pair? val) ;; (key . secret)
	      (or (string? (car val))
		  (packet? (car val))
		  (secret? (car val)))
	      (or (string? (cdr val)) 
		  (packet? (cdr val))
		  (secret? (cdr val))))
	 (store! aws:config 'aws:key (car val))
	 (store! aws:config 'aws:secret (cdr val)))
	((and (pair? val)
	      (or (string? (car val))
		  (packet? (car val))
		  (secret? (car val)) (car val))
	      (pair? (cdr val)) (null? (cddr val))
	      (or (string? (cadr val)) 
		  (packet? (cadr val))
		  (secret? (cadr val))))
	 (store! aws:config 'aws:key (car val))
	 (store! aws:config 'aws:secret (cadr val)))
	((or (slotmap? val) (schemap? val)) 
	 ;; #[aws:key vvv aws:secret sss ... ] or
	 ;; #[key vvv secret sss ... ]
	 (do-choices (key (getkeys val))
	   (store! aws:config 'aws:key (get val key)))
	 (when (and (test val 'key) (not (test val 'aws:key))) 
	   (store! aws:config 'aws:key (get val 'key)))
	 (when (and (test val 'secret) (not (test val 'aws:secret))) 
	   (store! aws:config 'aws:secret (get val 'secret))))
	((and (string? val) (file-exists? val))
	 (cond ((has-suffix val {".cfg" ".config"})
		(load-config val))
	       ((has-suffix val {".dtype" ".ztype"})
		(set-aws-config (file->dtype val)))
	       ((has-suffix val {".lsp" ".lisp" ".lispdat"})
		(set-aws-config (file->dtype val)))))
	((and (string? val) (exists? (text->frame key+secret val)))
	 (let ((match (text->frame key+secret val)))
	   (store! aws:config 'aws:key (get match 'key))
	   (store! aws:config 'aws:secret (get match 'secret))))
	((and (string? val) (position #\= val))
	 (handle-creds val cred-fields))
	((and (string? val) (config val))
	 (set-aws-config (config val)))
	(else (logwarn |BadAWSConfig| val))))
(config-def! 'aws:config
	     (lambda (var (val))
	       (if (not (bound? val))
		   aws:config
		   (set-aws-config val))))

;;; Signature support functions

(define (aws/datesig (date (timestamp)) (spec #{}))
  (unless date (set! date (timestamp)))
  (default! method (try (get spec 'method) "HmacSHA1"))
  ((if (test spec 'algorithm "HmacSHA256") hmac-sha256 hmac-sha1)
   (try (get spec 'secret) aws:secret)
   (get (timestamp date) 'rfc822)))

(define (aws/datesig/head (date (timestamp)) (spec #{}))
  (stringout "X-Amzn-Authorization: AWS3-HTTPS"
    " AWSAccessKeyId=" (try (get spec 'accesskey) aws:key)
    " Algorithm=" (try (get spec 'algorithm) "HmacSHA1")
    " Signature=" (packet->base64 (aws/datesig date spec))))

(define (aws/ok? (req #f) (err #f))
  (let ((key (getopt req 'aws:key aws:key))
	(secret (getopt req 'aws:secret aws:secret))
	(expires (getopt req 'aws:expires))
	(details (and (string? err) err)))
    (cond ((not key) (irritant req |NoAWSCredentials| details))
	  ((not secret) (irritant req |NoAWSSecret| details))
	  ((not expires) #t)
	  ((and aws/refresh (> (difftime expires) 3600))
	   (lognotice |RefreshToken| aws:key)
	   (aws/refresh req))
	  (else (irritant req |ExpiredAWSCredentials| details)))))

(define (aws/checkok (opts #f) (endpoint #t)) (aws/ok? opts endpoint))

(define (aws/set-creds! key secret (token #f) (expires #f) (refresh #f))
  (info%watch "AWS/SET-CREDS!" key secret token expires refresh)
  (set! aws:key key)
  (set! aws:secret secret)
  (set! aws:token token)
  (set! aws:expires expires)
  (set! aws/refresh refresh))

(define (aws/update-creds! opts key secret (token #f) (expires #f) (refresh #f))
  (if (or (not opts) (not (getopt opts 'aws:key)))
      (aws/set-creds! key secret token expires refresh)
      (let ((found (opt/find opts 'aws:key)))
	(store! found 'aws:key key)
	(store! found 'aws:secret secret)
	(when token (store! found 'aws:token token))
	(when expires (store! found 'aws:expires expires))
	(when refresh (store! found 'aws/refresh refresh)))))

(define (aws/creds! arg)
  (if (not arg)
      (begin (aws/set-creds! #f #f #f #f) #f)
      (let* ((spec (if (string? arg)
		       (if (has-prefix arg {"https:" "http:"})
			   (urlcontent arg)
			   (if (has-prefix arg { "/" "~/" "./"})
			       (filecontent arg)
			       arg))
		       arg))
	     (creds (if (string? spec) (jsonparse spec)
			(if (packet? spec) (packet->dtype spec)
			    spec))))
	(aws/set-creds! (try (get creds 'aws:key) (get creds 'accesskeyid))
			(try (->secret (get creds 'aws:secret))
			     (->secret (get creds 'secretaccesskey)))
			(try (get creds 'aws:token)
			     (get creds 'token)
			     #f)
			(try (get creds 'aws:expires)
			     (get creds 'expiration)
			     #f)
			#f)
	creds)))

;;;; Getting JSON templates for AWS APIs

(define (aws/template arg)
  (if (table? arg) arg
      (if (symbol? arg)
	  (if (string? (config arg))
	      (jsonparse (config arg))
	      (let ((found #f)
		    (name (glom (downcase arg) ".json")))
		(dolist (root template-sources)
		  (unless found
		    (when (gp/exists? (gp/mkpath root name))
		      (set! found (gp/mkpath root name)))))
		(if found
		    (jsonparse (gp/fetch found))
		    (irritant ARG |TemplateReference| aws/template
			      "Couldn't resolve template"))))
	  (if (string? arg)
	      (if (textsearch #{"{" "[" "\n"} arg)
		  (jsonparse arg))
	      (if (gp/exists? arg)
		  (jsonparse (gp/fetch arg))
		  (irritant ARG |Template| aws/template))))))

;;;; Extracting AWS error information

(define (aws/error result req)
  (let* ((content (get result '%content))
	 (ctype (try (get result 'content-type) #f))
	 (parsed (if (or (fail? content) (not content)
			 (zero? (length content)))
		     #f
		     (parse-error content ctype)))
	 (parsetype (tryif parsed (try (get parsed 'parsetype) #f)))
	 (extra #f))
    (cond ((and parsed (eq? parsetype 'xml)
		(exists? (xmlget parsed 'INVALIDSIGNATUREEXCEPTION)))
	   (set! extra
		 `#[INVALIDSIGNATUREEXCEPTION 
		    ,(xmlcontent (xmlget parsed 'INVALIDSIGNATUREEXCEPTION) 'message)
		    ACTION ,(getopt req "Action")
		    STRING-TO-SIGN ,(getopt req 'string-to-sign)
		    CREQ ,(getopt req 'creq)
		    DATE ,(getopt req 'date)
		    HEADERS ,(getopt req 'headers)
		    PARAMS ,(getopt req '%params)])))
    (when parsed
      (store! result '%content parsed))
    (store! result 'httpstatus (get result 'response))
    (if extra
	(cons* extra result req)
	(cons result req))))

(define (parse-error content type)
  (cond ((and type (search "/xml" type))
	 (xml-error (stringify content)))
	((and type (search "/json" type))
	 (json-error (stringify content)))
	(else (let ((string (stringify content)))
		(if (string-starts-with? string #((spaces*) "<"))
		    (xml-error string)
		    (json-error string))))))

(define (stringify arg)
  (if (string? arg) arg
      (if (packet? arg)
	  (packet->string arg)
	  (stringout arg))))

(define (xml-error xmlstring)
  (onerror
      (let* ((xmlopts (if (or (regex/search #/<html/i xmlstring)
			      (regex/search #/<body/i xmlstring))
			  '{sloppy data slotify}
			  '{data slotify}))
	     (err (remove-if string? (xmlparse xmlstring xmlopts))))
	(when (not (pair? err))
	  (irritant xmlstring |BadXMLErrorValue|))
	(store! (car err) 'parsetype 'xml)
	(car err))
      (lambda (ex)
	(logwarn  (error-condition ex)
	  "Couldn't parse XML error description:\n\t" ex 
	  "\n  " xmlstring)
	ex)))
(define (json-error jsonstring)
  (onerror
      (let ((err (jsonparse jsonstring)))
	(unless (table? err)
	  (irritant jsonstring |BadJSONErrorValue|))
	(store! err 'parsetype 'json)
	err)
      (lambda (ex)
	(logwarn  (error-condition ex)
	  "Couldn't parse JSON error description:\n\t" ex 
	  "\n  " jsonstring)
	ex)))



