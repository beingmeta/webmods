;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc. All rights reserved.
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu)

(in-module 'apis/twilio)

(use-module '{webtools texttools varconfig logger})

(module-export! '{twilio/send smsout sms/display sms/norm})

(define-init %loglevel %notify%)

(define-init default-sid
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567")
(varconfig! twilio:sid default-sid)

(define-init api-key #f)
(varconfig! twilio:apikey api-key)

(define-init api-secret #f)
(varconfig! twilio:apisecret api-secret)

(define-init default-from "+16175551212")
(varconfig! twilio:from default-from)

(define-init default-auth "abcdefghijklmnopqrstuvwxyz012345")
(varconfig! twilio:auth default-auth)

(define (get-basic-auth opts)
  (let ((username #f) (password #f))
    (cond ((getopt opts 'apikey)
	   (set! username (getopt opts 'apikey))
	   (set! password (getopt opts 'apisecret)))
	  ((getopt opts 'sid)
	   (set! username (getopt opts 'sid))
	   (set! password (getopt opts 'auth)))
	  (api-key
	   (set! username api-key)
	   (set! password api-secret))
	  (default-sid
	    (set! username default-sid)
	    (set! password default-auth)))
    (if (and username password)
	(glom username ":" password)
	(error |No Credentials| get-basic-auth
	       "Couldn't get TWILIO auth credentials"))))

(define (twilio/send string opts)
  (loginfo "Sending " (write string) " to " opts)
  (when (string? opts) (set! opts `#[to ,opts]))
  (let* ((endpoint (glom "https://api.twilio.com/2010-04-01/Accounts/"
		     (getopt opts 'sid default-sid)
		     "/Messages"))
	 (to (getopt opts 'to))
	 (from (getopt opts 'from default-from))
	 (req (urlpost endpoint `#[basicauth ,(get-basic-auth opts)]
		       "From" from
		       "To" to
		       "Body" string))
	 (response (get req 'response)))
    (info%watch "TWILIO/SEND" to from string endpoint header opts)
    (debug%watch "TWILIO/SEND" reponse req)
    (if (>= 299 response 200)
	response
	(if (getopt opts 'err)
	    (irritant req |TwilioFailed| opts)
	    (begin (logwarn |TwilioFailed|
		     "For " to " from " from " with body " string ":\n"
		     (pprint req))
		   response)))))

(define smsout
  (macro expr
    `(,twilio/send (stringout ,@(cddr expr)) ,(cadr expr))))

;;; Phone number functions

(define number-pat
  `(GREEDY
    (PREF
     #("+" (label cc (isdigit+)) (spaces*)
       "(" (label areacode #((isdigit) (isdigit) (isdigit))) ")"
       (spaces*)
       (label number
	      #((isdigit) (isdigit) (isdigit) (opt "-")
		(isdigit) (isdigit) (isdigit) (isdigit))))
     #("+" (label cc (isdigit+)) (spaces*)
       (label areacode (isdigit+)) 
       {(spaces*) "/" "-" "."}
       (label number
	      #((isdigit+) (* #({"." (spaces) "/" "-"} (isdigit+))))))
     #((opt "+") (opt (label cc "1"))
       (label areacode
	      #({"2" "3" "4" "5" "6" "7" "8" "9"} (isdigit) (isdigit)))
       {"-" "/" "." ""} (spaces*)
       (label number
	      #((isdigit) (isdigit) (isdigit)
		{(spaces) "-" "/" "." ""}
		(isdigit) (isdigit) (isdigit) (isdigit))))
     #("(" (label areacode #((isdigit) (isdigit) (isdigit))) ")"
       (spaces*)
       (label number
	      #((isdigit) (isdigit) (isdigit)
		{(spaces) "-" "/" "." ""}
		(isdigit) (isdigit) (isdigit) (isdigit)))))))

(define (sms/display string)
  (and (string? string)
       (let* ((match (text->frame number-pat string))
	      (cc (try (get match 'cc) 1))
	      (areacode (get match 'areacode))
	      (number (get match 'number)))
	 (and (exists? match)
	      (if (exists? areacode)
		  (stringout "+" cc "(" areacode ")" number)
		  (stringout "+" cc " "
		    (if (exists? areacode) (printout areacode " "))
		    (textsubst number '#{(spaces) "." "/" "-"} "")))))))
(define (sms/norm string)
  (if (number? string)
      (sms/norm (stringout string))
      (and (string? string)
	   (let* ((match (text->frame number-pat string))
		  (cc (get match 'cc))
		  (areacode (get match 'areacode))
		  (number (get match 'number)))
	     (when (and (or (fail? cc) (equal? cc "1") (eq? cc 1))
			(equal? (length number) 7))
	       (set! number
		     (glom (slice number 0 3) "-" (slice number 3))))
	     (and (exists? match)
		  (if (or (fail? cc) (equal? cc "1") (eq? cc 1))
		      (glom "+1(" areacode ")" number)
		      string))))))

