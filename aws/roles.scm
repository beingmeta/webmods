;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc.  All rights reserved.
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu).

(in-module 'aws/roles)

(use-module '{webtools texttools net/mimetable regex logctl opts
	      ezrecords kno/rulesets logger varconfig})
(use-module '{aws aws/v4 aws/ec2data})
(define %used_modules '{aws varconfig ezrecords kno/rulesets})

(define-init %loglevel %notice%)

(module-export! '{ec2/credentials ec2/role! ec2/role/creds!})

(define aws/role #f)
(define aws/userole #f)

(define-init credentials-cache (make-hashtable))

(define aws/role-root
  "http://169.254.169.254/latest/meta-data/iam/security-credentials/")
(varconfig! aws/roleroot aws/role-root)

(define (get-credentials role (error #f) (version "latest"))
  (if (not version) (set! version "latest"))
  (let* ((url (glom aws/role-root (downcase role)))
	 (response (urlget url))
	 (status (get response 'response))
	 (type (get response 'content-type)))
    (if (= status 200)
	(debug%watch (jsonparse (get response '%content)) response)
	(if (and error (not (number? error)))
	    (irritant response |BadEC2DataResponse| ec2/credentials)
	    (begin (logwarn |EC2 Credentials failed| url " status " status)
	      #f)))))

(define (ec2/credentials role (error #f) (cached))
  (set! cached (try (get credentials-cache role) #f))
  (if (and cached 
	   (or (not (test cached 'aws:expires))
	       (> (difftime (timestamp (get cached 'aws:expires)))
		    3600)))
      (begin (logdebug |EC2/Credentials| 
	       "Using cached credentials for '" role ",' "
	       "expiring in "
	       (secs->string (difftime (get cached 'aws:expires)))
	       " @" (get cached 'aws:expires))
	cached)
      (let* ((fresh (get-credentials role error))
	     (result (tryif fresh
		       (frame-create #f
			 'aws:key (get fresh 'accesskeyid)
			 'aws:secret (->secret (get fresh 'secretaccesskey))
			 'aws:expires (timestamp (get fresh 'expiration))
			 'aws:token (get fresh 'token)))))
	(when (and (exists? result) result)
	  (if (log>? %notice%)
	      (loginfo |EC2/Credentials| 
		"Got credentials for '" role "'\n "
		(pprint result))
	      (lognotice |EC2/Credentials| "Got credentials for '" role "'")))
	(store! credentials-cache role result)
	result)))

(define (ec2/rolecreds (role aws/role)) (get-credentials role))

(define (ec2/use-role! (role #f) (opts #f) (version "latest") (error #f))
  (if (not version) (set! version "latest"))
  (when (not role) (set! role (ec2/getrole)))
  (if (position #\| role)
      (let ((success #f))
	(loginfo |EC2SearchRoles| "Searching roles " role)
	(dolist (role (segment role "|"))
	  (unless success 
	    (if (ec2/use-role! role opts)
		(set! success role))))
	(when success 
	  (if (and opts (exists? (opt/find opts 'aws:key)))
	      (store! (opt/find opts 'aws:key) 'aws:role success)
	      (set! aws/role success)))
	success)
      (if (and aws:secret (not aws:token))
	  (begin
	    (logwarn |EC2KeepingCredentials|
	      "Keeping existing AWS credentials with key " aws:key)
	    (if (and opts (exists? (opt/find opts 'aws:key)))
		(store! (opt/find opts 'aws:key) 'aws:role role)
		(set! aws/role role))
	    role)
	  (let* ((creds (try (ec2/credentials role error) #f)))
	    (unless creds
	      (loginfo |AWS/ROLE| "Couldn't get credentials for " role))
	    (when creds
	      (if (test creds 'aws:expires)
		  (lognotice |AWS/ROLE|
		    "==" role "== with key " (get creds 'aws:key) " and "
		    "token expiring in "
		    (secs->string (difftime (get creds 'aws:expires)))
		    " @"  (get creds 'aws:expires))
		  (lognotice |AWS/ROLE|
		    role " with key=" (get creds 'aws:key) ", no expiration"))
	      (set! aws/role role)
	      (aws/update-creds! opts
				 (get creds 'aws:key)
				 (->secret (get creds 'aws:secret))
				 (try (get creds 'aws:token) #f)
				 (try (get creds 'aws:expires) #f)
				 (lambda args (ec2/role! role))))
	    (and creds aws:key role)))))

(define (ec2/role! (role #f) (version "latest") (error #f))
  (if (not version) (set! version "latest"))
  (when (not role) (set! role (ec2/getrole)))
  (if (position #\| role)
      (let ((success #f))
	(loginfo |EC2SearchRoles| "Searching roles " role)
	(dolist (role (segment role "|"))
	  (unless success (if (ec2/role! role) (set! success role))))
	(when success (set! aws/role success))
	success)
      (if (and aws:secret (not aws:token))
	  (begin
	    (logwarn |EC2KeepingCredentials|
	      "Keeping existing AWS credentials with key " aws:key)
	    (set! aws/role role)
	    role)
	  (let* ((creds (try (ec2/credentials role error) #f)))
	    (unless creds
	      (loginfo |AWS/ROLE| "Couldn't get credentials for " role))
	    (when creds
	      (if (test creds 'aws:expires)
		  (lognotice |AWS/ROLE|
		    "==" role "== with key " (get creds 'aws:key) " and "
		    "token expiring in "
		    (secs->string (difftime (get creds 'aws:expires)))
		    " @"  (get creds 'aws:expires))
		  (lognotice |AWS/ROLE|
		    role " with key=" (get creds 'aws:key) ", no expiration"))
	      (set! aws/role role)
	      (aws/set-creds! (get creds 'aws:key)
			      (->secret (get creds 'aws:secret))
			      (get creds 'aws:token)
			      (get creds 'aws:expires)
			      (lambda args (ec2/role! role))))
	    (and creds aws:key role)))))

(config-def! 'aws:role
	     (lambda (var (value))
	       (if (bound? value)
		   (and (not (overlaps? (and value (elts (segment value "|")))
					(and aws/role (elts (segment aws/role "|")))))
			(begin 
			  (if (ec2/live?)
			      (unless (ec2/role! value) 
				(logwarn |RoleFailed| "Couldn't set role to " value))
			      (begin (logwarn |RoleFailed| "Can't set role outside of EC2")
				(set! aws/role (car (segment value "|")))))
			  #t))
		   aws/role)))



