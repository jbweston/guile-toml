(define-module (hylophile toml builder)
  #:use-module (srfi srfi-1)
  #:use-module (json)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 string-fun)
  #:export (scm->toml value? toml-build-value toml-build-array toml-build-string))

(define-syntax-rule (log-exprs exp ...) (begin (format (current-error-port) "~a: ~S\n" (quote exp) exp) ...))

;; we want to be able to dynamically bind this functin in test-decoder.scm
;; TODO fix duplicate
(define value?
  (make-parameter
   (lambda (expr) (not (list? expr)))))

(define (value-pair? scm)
  (and (string? (car scm))
       ((value?) (cdr scm))))

(define (table-or-array-table? scm)
  (or (not (value-pair? scm))
      (array-table? (cdr scm))))

(define (array-table? v)
  (and (vector? v) (not (any (value?) (vector->list v)))))

(define (array-table-pair? scm)
  (array-table? (cdr scm)))
;; (define scm->value
;;   (lambda))
(define (build-newline port newline?)
  (when newline?
    (newline port)))

(define (toml-build-array-table-header keys port)
  (put-string port "[[")
  (build-keys keys port)
  (put-string port "]]"))

(define* (toml-build-array-table scm port #:optional (current-table '()))
  (define header (car scm))
  (define keys (append current-table (list header)))
  (define entries (vector->list (cdr scm)))
  (let loop ((entries entries))
    (unless (null? entries)
      (toml-build-array-table-header keys port)
      (build-newline port #t)
      (toml-build (car entries) port keys)
      (loop (cdr entries)))))

(define* (build-object-pair p port #:optional (current-table '())#:key (newline? #t) (inline? #f))
  (if (array-table? (cdr p))
      (toml-build-array-table p port current-table)
      (build-keyval p port #:newline? newline? #:inline? inline?)))

(define* (build-keyval p port #:key (newline? #t) (inline? #f))
  (build-key (car p) port)
  (put-string port " = ")
  (toml-build (cdr p) port #:newline? newline? #:inline? inline?))

(define* (escape-control-characters s #:optional (literal-nl? #f))
  (define (char->unicode-hex c)
    (define hex-unpadded (number->string (char->integer c) 16))
    (define zeroes (make-string (- 4 (string-length hex-unpadded)) #\0))
    (string-append "\\u" zeroes hex-unpadded))
  (apply string-append (map (lambda (c)
                              (cond
                               ((and literal-nl? (eq? c #\newline))
                                "\n")
                               ((eq? 'Cc (char-general-category c))
                                (char->unicode-hex c))
                               (else (string c))))
                            (string->list s))))

(define (toml-build-string s port)
  (define quote-type (if (or
                          (string-contains s "\\")
                          (string-contains s "\"")) #\' #\"))
  (define surround (if (string-contains s "\n")
                       (make-string 3 quote-type)
                       (string quote-type)))
  ;; (define surround (make-string 1 quote-type))
  (put-string port surround)
  (put-string port (escape-control-characters s #t))
  (put-string port surround))

(define (toml-build-boolean s port)
  (put-string port (if s "true" "false")))


(define (toml-build-key-string s port)
  (define quote-type (if (or
                          (string-contains s "\\")
                          (string-contains s "\"")) #\' #\"))
  (define surround (make-string 1 quote-type))
  (put-string port surround)
  (put-string port (escape-control-characters s))
  (put-string port surround))

(define (build-keys lst port)
  ;; TODO unicode keys
  ;; (put-string port (string-join lst "."))
  ;; (toml-build-string (string-join lst ".") port))
  (let loop ((lst lst))
    (if (null? (cdr lst))
        (build-key (car lst) port)
        (begin
          (build-key (car lst) port)
          (put-string port ".")
          (loop (cdr lst))))))

(define (build-key s port)
  (toml-build-key-string s port))

(define (build-table scm port current-table)
  (define new-table (append current-table (list (car scm))))
  (put-string port "[")
  (build-keys new-table port)
  (put-string port "]")
  (newline port)
  (toml-build (cdr scm) port new-table))

(define (values-then-array-tables a b)
  (let ((av? (array-table? (cdr a)))
        (bv? (array-table? (cdr b))))
    (cond
     ((and av? bv?) #t)
     (av? #f)
     (bv? #t))))

(define (toml-build-tree scm port current-table)
  (define pairs scm)
  (unless (null? pairs)
    (receive (tables keyvals)
        (partition table-or-array-table? pairs)
      ;; (log-exprs "." tables keyvals ".")
      (for-each (lambda (kv)
                  (build-object-pair kv port current-table))
                keyvals)
      (receive (array-tables std-tables)
          (partition array-table-pair? tables)
        ;; (log-exprs "_" array-tables std-tables "_")
        (for-each (lambda (t)
                    (build-table t port current-table))
                  std-tables)
        (for-each (lambda (kv)
                    (build-object-pair kv port current-table))
                  array-tables)))))

(define (build-delimited lst port)
  (unless (null? lst)
    (let loop ((lst lst))
      (if (null? (cdr lst))
          (toml-build (car lst) port #:newline? #f #:inline? #t)
          (begin (toml-build (car lst) port #:newline? #f #:inline? #t)
                 (put-string port ", ")
                 (loop (cdr lst)))))))

(define (build-delimited-pairs lst port)
  (unless (null? lst)
    (let loop ((lst lst))
      (if (null? (cdr lst))
          (build-object-pair (car lst) port #:newline? #f #:inline? #t)
          (begin (build-object-pair (car lst) port #:newline? #f #:inline? #t)
                 (put-string port ", ")
                 (loop (cdr lst)))))))

(define (toml-build-inline-tree scm port)
  (define pairs scm)
  (put-string port "{")
  (unless (null? pairs)
    (build-delimited-pairs pairs port))
  ;; (build-delimited pairs port))
  (put-string port "}"))

;; (build-object-pair (car pairs) port)
;; (for-each (lambda (p)
;;             (build-object-pair p port))
;;           (cdr pairs))
;; (newline port))))

(define (toml-build-array v port)
  (put-string port "[")
  (build-delimited (vector->list v) port)
  (put-string port "]"))

;; (define x (make-date 0 0 1 1 1 1 0 0))
;; (date->toml-datetime x)

(define (date->toml-datetime date)
  (define format (string-append
                  "~Y-~m-~dT~H:~M:~S"
                  (if (< 0 (date-nanosecond date)) ".~N" "")
                  "~z"))
  (date->string date format))

(define toml-build-value
  (make-parameter
   (lambda*
       (scm port #:key (newline? #t) (inline? #f))
     (cond
      ;; ((eq? scm null) (toml-build-null port))
      ((boolean? scm) (toml-build-boolean scm port))
      ;; ((symbol? scm) (toml-build-string (symbol->string scm) port))

      ;; TODO float (nan, inf)
      ((date? scm) (put-string port (date->toml-datetime scm)))
      ((vector? scm) (toml-build-array scm port))
      ((string? scm) (toml-build-string scm port))
      (else (display scm port)))
     (build-newline port newline?))))

(define* (toml-build scm port #:optional (current-table '())
                     #:key (newline? #t) (inline? #f))
  ;; (log-exprs scm)
  (cond
   ;; ((eq? scm null) (toml-build-null port))
   ;; ((boolean? scm) (toml-build-boolean scm port))
   ;; ((toml-number? scm) (toml-build-number scm port))
   ;; ((symbol? scm) (toml-build-string (symbol->string scm) port))
   ((null? scm)
    (and inline? (toml-build-inline-tree '() port)))
   (((value?) scm)
    ((toml-build-value) scm port #:newline? newline? #:inline? inline?))
   ((array-table? (and (list? scm) (cdr scm)))
    (toml-build-array-table scm port))
   ((or (pair? scm) (null? scm))
    (if inline?
        (toml-build-inline-tree scm port)
        (toml-build-tree scm port current-table))))

  (build-newline port newline?))
;; (else (throw 'toml-invalid scm))))

(define* (scm->toml scm
                    #:optional (port (current-output-port)))
  (toml-build scm port))

;; (scm->toml '(("a" . "b") ("c" . "d")))
;; (scm->toml '(("yo" ("a" . "b"))))
;; (scm->toml '(("hi"
;;               ("yo" ("a" . "b") ("c" . "d"))
;;               ;; ("e" . #("f" "b" (("a" . "b")))) TODO inline-tables
;;               ("e" . #("f" "b" "g")))
;;              ("g" . "p")))

;; '(("servers"
;;    ("beta" ("role" . "backend") ("ip" . "10.0.0.2"))
;;    ("alpha"
;;     ("role" . "frontend")
;;     ("ip" . "10.0.0.1")))
;;   ("database"
;;    ("temp_targets" ("case" . 72.0) ("cpu" . 79.5))
;;    ("data" . #(#("delta" "phi") #(3.14)))
;;    ("ports" . #(8000 8001 8002))
;;    ("enabled" . #t))
;;   ("owner"
;;    ("dob"
;;     . "date")
;;    ("name" . "Tom Preston-Werner"))
;;   ("title" . "TOML Example"))

;; '()


;; (define (values-first a b)
;;   (let ((av? ((value?) a))
;;         (bv? ((value?) b)))
;;    (cond
;;     ((and av? bv?) #t)
;;     (av? #t)
;;     (bv? #f))))
