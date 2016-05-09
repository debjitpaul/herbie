#lang racket

;; Periodicity analysis
;
; Given a mathematical formula, determines which components are periodic,
; which variables they are periodic in, and the associated periods.
;
; The basic process is abstract interpretation, where each subexpression
; is classified, for every variable, as one of:
;  - Constant (and the value)
;  - Linear (and the coefficient)
;  - Periodic (and the period)
;  - Other
;
; Known periodic functions, like sin or cotan, transform linear
; expressions into periodic expressions. Periods are then properly
; bubbled up the expression tree.

(require racket/match)
(require "common.rkt")
(require (except-in "programs.rkt" constant?))
(require "rules.rkt")
(require "alternative.rkt")
(require "points.rkt")
(require "matcher.rkt")

(struct annotation (expr loc type coeffs) #:transparent)
(struct lp (loc periods) #:prefab)

(provide optimize-periodicity (struct-out lp))

(define (constant? a) (eq? (annotation-type a) 'constant))
(define (linear? a)   (eq? (annotation-type a) 'linear))
(define (periodic? a) (or (eq? (annotation-type a) 'periodic) (interesting? a)))
(define (interesting? a) (eq? (annotation-type a) 'interesting))
(define (other? a) (eq? (annotation-type a) 'other))
(define coeffs annotation-coeffs)

(define (alist-merge merge . as)
  (define (merge-2 a b)
    (cond
     [(null? a) b]
     [(null? b) a]
     [(eq? (caar a) (caar b))
      (cons (cons (caar a) (merge (cdar a) (cdar b)))
            (merge-2 (cdr a) (cdr b)))]
     [(symbol<? (caar a) (caar b))
      (cons (car a) (merge-2 (cdr a) b))]
     [(symbol<? (caar b) (caar a))
      (cons (car b) (merge-2 a (cdr b)))]
     [else
      (error "Something horrible has happened" a b)]))
  (foldl merge-2 '() as))

(define (alist-map f al)
  (for/list ([rec al])
    (cons (car rec) (f (cdr rec)))))

(define (default-combine expr loc special)
  (cond
   [special special]
   [(andmap constant? (cdr expr))
    (annotation expr loc 'constant
                (common-eval (cons (car expr) (map coeffs (cdr expr)))))]
   [(and (andmap periodic? (cdr expr)) (= 3 (length expr)))
    (annotation expr loc 'interesting
		(apply alist-merge lcm
		       (map coeffs (filter periodic? (cdr expr)))))]
   [(andmap (λ (x) (or (periodic? x) (constant? x))) (cdr expr))
    (annotation expr loc 'periodic
                (apply alist-merge lcm
                       (map coeffs (filter periodic? (cdr expr)))))]
   [else
    (annotation expr loc 'other #f)]))

(define (periodic-locs prog)
  (define (lp-loc-cons loc-el locp)
    (lp (cons loc-el (lp-loc locp)) (lp-periods locp)))
  (define (annot->plocs annot)
    (cond [(interesting? annot)
	   `(,(lp '() (coeffs annot)))]
	  [(other? annot)
	   (apply append
		  (let ([inner-annots (cdr (annotation-expr annot))])
		    (map (λ (lps base-loc)
			   (map (curry lp-loc-cons base-loc) lps))
			 (map annot->plocs inner-annots)
			 (map add1 (range (length inner-annots))))))]
	  [else '()]))
  (map (curry lp-loc-cons 2) (annot->plocs (program-body (periodicity prog)))))

(define (periodicity prog)
  (define vars (program-variables prog))
  
  (location-induct
   prog

   #:constant
   (λ (c loc)
      ; TODO : Do something more intelligent with 'pi
      (let ([val (if (rational? c) c (->flonum c))])
	(annotation val loc 'constant val)))

   #:variable
   (λ (x loc)
      (annotation x loc 'linear `((,x . 1))))

   #:primitive
   (λ (expr loc)
      (define out (curry annotation expr loc))

      ; Default-combine handles function-generic things
      ; The match below handles special cases for various functions
      (default-combine expr loc
        (match expr
          [`(+ ,a ,b)
           (cond
            [(and (constant? a) (linear? b))
             (out 'linear (coeffs b))]
            [(and (linear? a) (constant? b))
             (out 'linear (coeffs a))]
            [(and (linear? a) (linear? b))
             (out 'linear (alist-merge + (coeffs a) (coeffs b)))]
            [else #f])]
          [`(- ,a)
           (cond
            [(linear? a)
             (out 'linear (alist-map - (coeffs a)))]
	    [else #f])]
          [`(- ,a ,b)
           (cond
            [(and (constant? a) (linear? b))
             (out 'linear (coeffs b))]
            [(and (linear? a) (constant? b))
             (out 'linear (coeffs a))]
            [(and (linear? a) (linear? b))
             (out 'linear (alist-merge - (coeffs a) (coeffs b)))]
            [else #f])]

          [`(* ,a ,b)
           (cond
            [(and (linear? a) (constant? b))
             (out 'linear (alist-map (curry * (coeffs b)) (coeffs a)))]
            [(and (constant? a) (linear? b))
             (out 'linear (alist-map (curry * (coeffs a)) (coeffs b)))]
            [else #f])]
          [`(/ ,a ,b)
           (cond
            [(and (linear? a) (constant? b))
             (if (= 0 (coeffs b))
                 (out 'constant +nan.0)
                 (out 'linear (alist-map (curryr / (coeffs b)) (coeffs a))))]
            [else #f])]

          ; Periodic functions record their period
          ;         AS A MULTIPLE OF 2*PI
          ; This prevents problems from round-off
          [`(sin ,a)
           (cond
            [(linear? a)
             (out 'periodic (alist-map / (coeffs a)))]
            [else #f])]
          [`(cos ,a)
           (cond
            [(linear? a)
             (out 'periodic (alist-map / (coeffs a)))]
            [else #f])]
          [`(tan ,a)
           (cond
            [(linear? a)
             (out 'periodic (alist-map / (coeffs a)))]
            [else #f])]
          [`(cotan ,a)
           (cond
            [(linear? a)
             (out 'periodic (alist-map / (coeffs a)))]
            [else #f])]

          [_ #f])))))

(define (optimize-periodicity improve-func altn)
  (debug "Optimizing " altn " for periodicity..." #:from 'periodicity #:depth 2)
  (let* ([plocs (periodic-locs (alt-program altn))]
	 [oalts (map (λ (ploc)
		       (let* ([vars (map car (lp-periods ploc))]
			      [program `(λ ,vars ,(location-get (lp-loc ploc) (alt-program altn)))])
			 (debug "Looking at subexpression " program #:from 'periodicity #:depth 4)
			 (if (or (> (apply max (map cdr (lp-periods ploc))) *max-period-coeff*))
			     altn
			     (let ([context
				    (prepare-points-period
				     program
				     (map (compose (curry * 2 pi) cdr) (lp-periods ploc)))])
			       (parameterize ([*pcontext* context])
				 (improve-func (make-alt program)))))))
		     plocs)]
	 ;; Substitute (mod x period) for x in any conditionals
	 [oexprs (map coerce-conditions
		      (map alt-program oalts)
		      (map lp-periods plocs))]
         [final-prog
          (for/fold ([prog (alt-program altn)]) ([oexpr oexprs] [ploc plocs])
            (location-do (lp-loc ploc) prog (const oexpr)))])
    (debug #:from 'periodicity "Periodicity result: " final-prog)
    (if (not (null? oalts))
        (alt-event final-prog 'periodicity (cons altn oalts))
        altn)))

(define (symbol-mod v periods)
  (if (assoc v periods)
      (let ([coeff (cdr (assoc v periods))])
        `(mod ,v ,(if (= 1/2 coeff) 'PI `(* ,(* 2 coeff) PI))))
      v))

(define (coerce-conditions prog periods)
  (let loop ([cur-body (program-body prog)])
    (match cur-body
      [`(if ,cond ,a ,b)
       `(if ,(expression-induct cond (program-variables prog) #:variable (curryr symbol-mod periods))
	    ,(loop a) ,(loop b))]
      [_ cur-body])))
