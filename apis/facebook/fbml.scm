;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc.  All rights reserved.
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu).

(in-module 'apis/facebook/fbml)

;;; Outputting FBML (FaceBook Markup Language)

(use-module '{webtools xhtml})

(define (fb:name (id #f))
  (if id (xmlelt "fb:name" 'uid (stringout id))
       (xmlelt "fb:name")))

(module-export! 'fb:name)

