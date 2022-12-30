(define-module (toml)
  #:use-module (toml parser)
  #:use-module (ice-9 peg)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 match)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  ;; TODO exporting flatten-array isn't nice, it's an internal function.
  #:export (toml->scm flatten-array value->scm value?))


(define-syntax-rule (log-exprs exp ...) (begin (format #t "~a: ~S\n" (quote exp) exp) ...))

(define (flatten-array l)
  (keyword-flatten '(array dec-int float string bola) l))

(define (get-keys l)
  (map cadr (keyword-flatten '(simple-key) l)))

;; we want to be able to dynamically bind this function in test-decoder.scm
;; TODO would be nicer if we didn't have to export flatten-array
(define value->scm
  (make-parameter
   (lambda (v)
     (match v
       (('array vs ...)
        ;; (pretty-print (flatten-array vs))
        (list->vector (map (value->scm) (flatten-array vs))))
       ;; (format #f "array ~a" (flatten-array vs)))
       ((x y)
        ;; (single-value-proc x y)
        ;; (annot-v-proc x y))
        y)
       ;; (format #f "type: ~a, value: ~a" x y))
       ('()
        '())
       ;; ('inline-table
       ;;  '())
       (_ (error "err:" v))))))

;; ((value->scm) '(x "2"))

(define (keyval->scm keys value)
  (let loop ((keys keys))
    (if (null? (cdr keys))
        (cons (car keys) ((value->scm) (car value)))
        (list (car keys) (loop (cdr keys))))))

;; we want to be able to dynamically bind this functin in test-decoder.scm
(define value?
  (make-parameter
   (lambda (expr) (not (list? expr)))))

(define (add-to-tree tree keys value)
  ;; (pretty-print value)
  (if (null? keys)
      ;; TODO helper to never call this on top-level
      ((value->scm) value)
      (let ((k (list-index (lambda (x) (equal? x (car keys))) (map car tree))))
        (if k
            (let ((e (list-ref tree k)))
              ;; (pretty-print e)
              (when ((value?) e)
                (error "guile-toml: redefinition not allowed"))
              (append
               (take tree k)
               (list (cons
                      (car e)
                      (add-to-tree (cdr e) (cdr keys) value)))
               (drop tree (1+ k))))
            (cons (keyval->scm keys value) tree)))))

(define (heads lst)
  (map (lambda (k) (list-head lst k)) (iota (length lst) 1)))

(define (check-inline-table-keys keylist inline-table-keys)
  (let ((heads (map (lambda (k) (list-head keylist k))
                    (iota (length keylist) 1))))
    (when (any (lambda (x) (member x inline-table-keys))
               heads)
      (error "guile-toml: redefinition not allowed"))))

(define (toml->scm s)
  (define tree (parse s))
  (let loop ((tree (if (symbol? (car tree)) (list tree) tree))
             (result '())
             (current-table '())
             (inline-table-keys '()))
    ;; (pretty-print tree)
    (match (car tree)
      (('keyval keys 'inline-table)
       (let ((keylist (append current-table (get-keys keys))))
         (set! inline-table-keys (cons keylist inline-table-keys))
         (set! result (add-to-tree result keylist '(())))))
      (('keyval keys ('inline-table keyvals ...))
       (set! result
             (loop (keyword-flatten '(keyval) keyvals)
                   result
                   (get-keys keys)
                   '())))
      (('keyval keys value ...)
       (let ((keylist (append current-table (get-keys keys))))
         (check-inline-table-keys keylist inline-table-keys)
         (set! result (add-to-tree result keylist value))))
      (('std-table keys ...)
       (let ((keylist (get-keys keys)))
         (check-inline-table-keys keylist inline-table-keys)
         (set! result (add-to-tree result keylist '(())))
         (set! current-table keylist)))

      (x (format #t "~a ; unknown: ~a\n" tree x)))

    (if (null? (cdr tree))
        result
        (loop (cdr tree) result current-table inline-table-keys))))

