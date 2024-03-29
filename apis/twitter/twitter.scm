;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc.  All rights reserved.
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu)

(in-module 'apis/twitter)

(use-module '{webtools texttools reflection varconfig text/parsetime logger})
(use-module '{xhtml xhtml/auth net/oauth kno/xconfig})

(module-export! '{twitter/creds twitter/limits twitter-root})
(module-export! '{twitter/throttled? twitter/throttled!})

(define-init %loglevel %notice%)
(define-init throttled (make-hashtable))

(define twitter-root "https://api.twitter.com/1.1/")

(define init-creds 'twitter20)
(define twitter-creds #f)

(define (twitter/creds (init init-creds))
  (or (and twitter-creds (not init))
      (let ((creds (oauth/getclient init)))
	(set! twitter-creds creds)
	creds)))

(define (twitter/limits creds (family #f))
  (oauth/call (cons #[jsonflags 0] creds) 
	      (glom twitter-root "application/rate_limit_status.json")
	      (and family `#["resources" family])))

#|
(define (twitter/throttled? creds (resource #f) (key))
  (default! key
    (if (table? creds)
	(get creds 'token)
	creds))
  (and (test throttled key)
       (let ((until (get throttled key)))
	 (or (fail? until) 
	     (and (past? until) (begin (drop! throttled key) #t))))))

(define (twitter/throttled! creds (until) (key))
  (default! key
    (if (table? creds)
	(get creds 'token)
	creds))
  (and (test throttled key)
       (let ((until (get throttled key)))
	 (or (fail? until) 
	     (and (past? until) (begin (drop! throttled key) #t))))))
|#
