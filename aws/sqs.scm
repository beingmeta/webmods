;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2020 beingmeta, inc.  All rights reserved.
;;; Copyright (C) 2020-2022 Kenneth Haase (ken.haase@alum.mit.edu).

(in-module 'aws/sqs)

(use-module '{aws aws/v4 texttools logger varconfig})
(define %used_modules '{apis/aws varconfig})

(module-export! '{sqs/get sqs/list sqs/info
		  sqs/send! sqs/delete!
		  sqs/send sqs/delete
		  sqs/extend sqs/req/extend
		  sqs/getn sqs/vacuum})

(define-init %loglevel %notice%)

(define sqs-endpoint "https://sqs.us-east-1.amazonaws.com/")
(varconfig! sqs:endpoint sqs-endpoint)

(define (sqs-field-pattern name (label) (parser #f))
  (default! label (string->lisp name))
  `#(,(glom "<" name ">")
     (label ,label (not> ,(glom "</" name ">")) ,parser)
     ,(glom "</" name ">")))
(define (sqs-attrib-pattern name (label) (parser #f))
  (default! label (string->lisp name))
  `#("<Attribute><Name>" ,name "</Name><Value>"
     (label ,label (not> "</Value>") ,parser)
     "</Value></Attribute>"))

(define queue-opts (make-hashtable))

(define sqs-fields
  {(sqs-field-pattern "Body")
   (sqs-field-pattern "ReceiptHandle" 'handle)
   (sqs-field-pattern "MessageId" 'msgid)
   (sqs-field-pattern "RequestId" 'reqid)
   (sqs-field-pattern "QueueUrl" 'queue)
   (sqs-field-pattern "SenderId" 'sender)
   (sqs-field-pattern "SentTimestamp" 'sent)
   (sqs-field-pattern "ApproximateReceiveCount")
   (sqs-field-pattern "ApproximateFirstReceiveTimestamp")})

(define (timevalue x) (timestamp (->number x)))

(define sqs-info-fields
  {(sqs-attrib-pattern "ApproximateNumberOfMessages" 'count #t)
   (sqs-attrib-pattern "ApproximateNumberOfMessagesNotVisible" 'inflight #t)
   (sqs-attrib-pattern "ApproximateNumberOfMessagesDelayed" 'delayed #t)
   (sqs-attrib-pattern "VisibilityTimeout" 'interval #t)
   (sqs-attrib-pattern "CreatedTimestamp" 'created timevalue)
   (sqs-attrib-pattern "LastModifiedTimestamp" 'modified timevalue)
   (sqs-attrib-pattern "Policy")
   (sqs-attrib-pattern "MaximumMessageSize" 'maxmsg #t)
   (sqs-attrib-pattern "MessageRetentionPeriod" 'retention #t)
   (sqs-attrib-pattern "QueueArn" 'arn #f)
   (sqs-attrib-pattern "ReceiveMessageWaitTimeSeconds" 'timeout #t)
   (sqs-attrib-pattern "DelaySeconds" 'delay #t)})

(define (handle-sqs-response result (opts #f) (extract))
  (default! extract (getopt opts 'extract sqs-fields))
  (debug%watch "handle-sqs-response" result)
  (if (and result (table? result) (getopt result 'response)
	   (>= 299 (getopt result 'response) 200))
      (let* ((combined (frame-create #f
			 'queue (getopt result '%queue {})
			 'received (gmtimestamp)))
	     (content (getopt result '%content))
	     (fields (tryif content (text->frames extract content))))
	(if (or (fail? fields) (fail? (get fields 'msgid)))
	    (begin (debug%watch content fields) #f)
	    (begin (debug%watch fields)
	      (do-choices (field fields)
		(do-choices (key (getkeys field))
		  (add! combined key (get field key))))
	      combined)))
      (begin (when (getopt opts 'logerr #t) (loginfo |SQSFailure| result))
	#f)))

(define (handle-sqs-error ex method queue (trouble))
  (default! trouble
    (and (error-irritant? ex) (error-irritant ex)))
  (if irritant
      (irritant trouble |SQS/Failed| "Received from " method " " queue)
      (error |SQS/Failed| "Received from " method " " queue)))

(define (get-queue-opts (queue #f) (opts #[]) (qopts))
  (default! qopts (try (tryif queue (get queue-opts queue)) #[]))
  (frame-create #f '%queue (tryif queue queue) 'err #f))

(define (sqs/get queue (opts #[])
		 (args `#["Action" "ReceiveMessage" "AttributeName.1" "all"]))
  (when (getopt opts 'wait)
    (store! args "WaitTimeSeconds" (getopt opts 'wait)))
  (when (getopt opts 'reserve)
    (store! args "VisibilityTimeout" (getopt opts 'reserve)))
  (handle-sqs-response 
   (aws/v4/op (get-queue-opts queue opts)
	      "GET" queue opts args)
   (cons #[logerr #f] opts)))

(define (sqs/send! queue msg (opts #[]) (args `#["Action" "SendMessage"]))
  (store! args "MessageBody" msg)
  (when (getopt opts 'delay) (store! args "DelaySeconds" (getopt opts 'delay)))
  (onerror
      (handle-sqs-response 
       (aws/v4/get (get-queue-opts queue opts) queue opts args))
    (lambda (ex)
      (handle-sqs-error ex '|SendMessage| queue))))
(define (sqs/send queue msg (opts #[]) (args `#["Action" "SendMessage"]))
  (sqs/send! queue msg opts args))

(define (sqs/list (prefix #f) (args #["Action" "ListQueues"]) (opts #[]))
  (when prefix (set! args `#["Action" "ListQueues" "QueueNamePrefix" ,prefix]))
  (onerror
      (handle-sqs-response 
       (aws/v4/get (get-queue-opts #f opts) sqs-endpoint opts args))
    (lambda (ex)
      (handle-sqs-error ex '|ListQueues| #f))))

(define (sqs/info queue
		  (args #["Action" "GetQueueAttributes" "AttributeName.1" "All"])
		  (opts #[]))
  (onerror
      (handle-sqs-response
       (aws/v4/get (get-queue-opts queue opts) queue opts args)
       (qc sqs-info-fields))
    (lambda (ex)
      (handle-sqs-error ex '|GetQueueAttributes| queue))))

(define (sqs/delete! message (opts #[]) (queue) (handle))
  (cond ((and (pair? message) (string? (car message)))
	 (set! queue (car message))
	 (set! handle (cdr message)))
	((and (string? message) (has-prefix message "https:")
	      (position #\| message))
	 (set! queue (slice message 0 (position #\| message)))
	 (set! handle (slice message (1+ (position #\| message)))))
	((and (table? message) (test message 'queue) (test message 'handle)
	      (string? (get message 'queue))
	      (string? (get message 'handle)))
	 (set! queue (get message 'queue))
	 (set! handle (get message 'handle)))
	(else (irritant message |BadSQSRef| sqs/delete!)))
  (onerror
      (handle-sqs-response
       (aws/v4/get (get-queue-opts queue) queue opts
		   `#["Action" "DeleteMessage" "ReceiptHandle" ,handle]))
      (lambda (ex)
	(handle-sqs-error ex '|DeleteMessage| (get message 'queue)))))
(define (sqs/delete message (opts #[])) (sqs/delete! message opts))

(define (sqs/extend message secs (opts #[]))
  (onerror
      (handle-sqs-response
       (aws/v4/get (get-queue-opts (get message 'queue))
		   (get message 'queue) opts
		   `#["Action" "ChangeMessageVisibility"
		      "ReceiptHandle" ,(get message 'handle)
		      "VisibilityTimeout" ,secs]))
    (lambda (ex)
      (handle-sqs-error ex '|ExtendMessage| (get message 'queue)))))

(define reqvar '_sqs)
(define default-extension 60)
(varconfig! sqs:extension default-extension)
(varconfig! sqs:reqvar reqvar)

(define (sqs/req/extend (secs #f))
  (when (req/test reqvar)
    (let ((entry (req/get reqvar)))
      (and (or (pair? entry) (table? entry))
	   (testopt entry 'handle) (testopt entry 'queue)
	   (sqs/extend `#[handle ,(getopt entry 'handle)
			  queue ,(getopt entry 'queue)]
		       (or secs (getopt entry 'extension
					default-extension)))))))

;;; GETN returns multiple items from a queue (#f means all)

(define (sqs/getn queue (n #f))
  (let ((item (sqs/get queue)) (count 0) (result {})
	(seen (make-hashset)))
    (until (or (not item) (and n (>= count n)))
      (unless (get seen (get item 'msgid))
	(hashset-add! seen (get item 'msgid))
	(set+! result item))
      (set! count (1+ count))
      (set! item (sqs/get queue)))
    result))

;;; Vacuuming removes all the entries from a queue

(define (sqs/vacuum queue)
  (let ((item (sqs/get queue)) (count 0))
    (while item
      (sqs/delete item)
      (set! count (1+ count))
      (set! item (sqs/get queue)))
    count))
