;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc. All rights reserved
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu).

(in-module 'xhtml/download)

(use-module '{webtools xhtml reflection net/mimetable varconfig})
(define %used_modules '{varconfig})

(define havezip (get-module 'ziptools))
(when havezip (use-module 'ziptools))

(module-export! 'xhtml/download)

(define boundary "<frontier>")
(define tmpdir #f)

(varconfig! xhtml/boundary boundary)

(define (xhtml/download . specs)
  "Takes an alternating list of filenames and contents"
  (when (> (length specs) 2)
    (if (try (thread/get 'usezip) (req/get 'usezip) #f)
	(zipfile-download specs)
	(multipart-download specs)))
  (when (<= (length specs) 2)
    (let* ((spec (car specs))
	   (info (if (string? spec) #[] spec))
	   (name (if (string? spec) spec (get spec 'filename)))
	   (content (if (= (length specs) 2) (cadr specs)
			(get info 'content)))
	   (type (try (get info 'content-type) (guess-content-type name content)
		      "text; charset=utf-8")))
      (req/set! 'content-type type)
      (httpheader (stringout "Content-Disposition: attachment; filename=" name))
      (write-content content))))

(define (multipart-download specs)
  (let ((boundary (try (thread/get 'xhtml/boundary)
		       (req/get 'xhtml/boundary)
		       boundary)))
    (req/set! 'content-type
	     (stringout "multipart/mixed; boundary=" boundary))
    (httpheader "Mime-Version: 1.0")
    (xhtml "\nThis response contains " (/ (length specs) 2) " files\n")
    (do ((scan specs
	       (if (and (not (string? (car scan)))
			(test (car scan) 'content))
		   (cdr scan)
		   (cddr scan))))
	((null? scan)
	 (xhtml "\r\n--" boundary "--\r\n"))
      (xhtml "\r\n--" boundary "\r\n")
      (if (and (not (string? (car scan))) (test (car scan) 'content))
	  (write-attachment (car scan) (get (car scan) 'content))
	  (write-attachment (car scan) (cadr scan))))))

(define (zipfile-download specs)
  (let* ((name (try (thread/get 'zipfilename)
		    (req/get 'zipfilename)
		    (if (string? (car specs))
			(string-append (basename (car specs) #t) ".zip")
			(tryif (table? (car specs))
			  (string-append (basename (get (car specs) 'filename) #t))))
		    "download"))
	 (zipname (mkpath (try (thread/get 'tmpdir) (req/get 'tmpdir)
			       (or tmpdir (getenv "TMPDIR") "/tmp"))
			  (string-append (uuid->string (getuuid)) ".zip")))
	 (zipfile (zip/make zipname)))
    (do ((scan specs
	       (if (and (not (string? (car scan)))
			(test (car scan) 'content))
		   (cdr scan)
		   (cddr scan))))
	((null? scan) (zip/close zipfile)
	 (req/set! 'content-type "application/zip")
	 (httpheader (stringout "Content-Disposition: attachment; filename=" name))
	 (req/set! 'retfile zipname)
	 (req/set! 'cleanup (lambda () (remove-file zipname))))
      (let* ((spec (car scan))
	     (info (if (string? spec) #[] spec))
	     (name (if (string? spec) spec (get spec 'filename)))
	     (content (if (string? spec) (cadr scan)
			  (try (get spec 'content) (cadr scan)))))
	(zip/add! zipfile name
		  (if (applicable? content)
		      (stringout (content))
		      (if (or (string? content) (packet? content))
			  content
			  (stringout (xhtml content)))))))))

(define (write-attachment spec content)
  (let* ((info (if (string? spec) #[] spec))
	 (name (if (string? spec) spec (get spec 'filename)))
	 (type (try (get info 'content-type) (guess-content-type name content)
		    "text; charset=utf-8")))
    (xhtml "Content-Type: " type "\r\n")
    (when (packet? content) (xhtml "Content-Encoding: base64\r\n"))
    (xhtml "Content-Disposition: attachment; filename=" name "\r\n\r\n")
    (write-content content)))
(define (write-content content)
  (if (string? content) (xhtml content)
      (if (packet? content)
	  (let* ((base64 (packet->base64 content))
		 (nlines (1+ (quotient (length base64) 60))))
	    (dotimes (i (1+ (quotient (length base64) 60)))
	      (xhtml (subseq base64 (* i 60)
			     (and (< (1+ i) nlines) (* (1+ i) 60)))
		"\n")))
	  (if (and (table? content) (test content '%xmltag))
	      (xmleval content)
	      (if (applicable? content) (content)
		  (xhtml content))))))

(define (guess-content-type name content)
  (path->mimetype name "text; charset=utf-8"))

