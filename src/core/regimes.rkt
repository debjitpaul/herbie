#lang racket

(require "../common.rkt")
(require "../config.rkt")
(require "../alternative.rkt")
(require "../programs.rkt")
(require "../points.rkt")
(require "../float.rkt")
(require "../syntax/syntax.rkt")
(require "../syntax/distributions.rkt")
(require "matcher.rkt")
(require "localize.rkt")

(module+ test
  (require rackunit))

(provide infer-splitpoints (struct-out sp) splitpoints->point-preds)

(define (infer-splitpoints alts [axis #f])
  (debug "Finding splitpoints for:" alts #:from 'regime-changes #:depth 2)
  (let* ([options (map (curry option-on-expr alts)
		       (if axis (list axis)
			   (exprs-to-branch-on alts)))]
	 [best-option (argmin (compose errors-score option-errors) options)]
	 [splitpoints (option-splitpoints best-option)]
	 [altns (used-alts splitpoints alts)]
	 [splitpoints* (coerce-indices splitpoints)])
    (debug #:from 'regimes "Found splitpoints:" splitpoints* ", with alts" altns)
    (list splitpoints* altns)))

(struct option (splitpoints errors) #:transparent
	#:methods gen:custom-write
        [(define (write-proc opt port mode)
           (display "#<option " port)
           (write (option-splitpoints opt) port)
           (display ">" port))])

(define (exprs-to-branch-on alts)
  (define critexpr (critical-subexpression (*start-prog*)))
  (define vars (program-variables (alt-program (car alts))))

  (if critexpr
      (cons critexpr vars)
      vars))

(define (critical-subexpression prog)
  (define (loc-children loc subexpr)
    (map (compose (curry append loc)
		  list)
	 (range 1 (length subexpr))))
  (define (all-equal? items)
    (if (< (length items) 2) #t
	(and (equal? (car items) (cadr items)) (all-equal? (cdr items)))))
  (define (critical-child expr)
    (let ([var-locs
	   (let get-vars ([subexpr expr]
			  [cur-loc '()])
	     (cond [(list? subexpr)
		    (append-map get-vars (cdr subexpr)
				(loc-children cur-loc subexpr))]
		   [(constant? subexpr)
		    '()]
		   [(variable? subexpr)
		    (list (cons subexpr cur-loc))]))])
      (cond [(null? var-locs) #f]
            [(all-equal? (map car var-locs))
             (caar var-locs)]
            [#t
             (let get-subexpr ([subexpr expr] [vlocs var-locs])
               (cond [(all-equal? (map cadr vlocs))
                      (get-subexpr (if (= 1 (cadar vlocs)) (cadr subexpr) (caddr subexpr))
                                   (for/list ([vloc vlocs])
                                     (cons (car vloc) (cddr vloc))))]
                     [#t subexpr]))])))
  (let* ([locs (localize-error prog)])
    (if (null? locs)
        #f
        (critical-child (location-get (car locs) prog)))))

(define basic-point-search (curry binary-search (λ (p1 p2)
						  (if (for/and ([val1 p1] [val2 p2])
							(> *epsilon-fraction* (abs (- val1 val2))))
						      p1
						      (for/list ([val1 p1] [val2 p2])
							(/ (+ val1 val2) 2))))))

(define (used-alts splitpoints all-alts)
  (let ([used-indices (remove-duplicates (map sp-cidx splitpoints))])
    (map (curry list-ref all-alts) used-indices)))

;; Takes a list of splitpoints, `splitpoints`, whose indices originally referred to some list of alts `alts`,
;; and changes their indices so that they are consecutive starting from zero, but all indicies that
;; previously matched still match.
(define (coerce-indices splitpoints)
  (let* ([used-indices (remove-duplicates (map sp-cidx splitpoints))]
	 [mappings (map cons used-indices (range (length used-indices)))])
    (map (λ (splitpoint)
	   (sp (cdr (assoc (sp-cidx splitpoint) mappings))
	       (sp-bexpr splitpoint)
	       (sp-point splitpoint)))
	 splitpoints)))

(define (option-on-expr alts expr)
  (define vars (program-variables (*start-prog*)))
  ;; A table of rows pt, ex, f(pt), err_i(pt, ex), sorted by f(pt)
  (define table
    (sort
     (flip-lists
      (append
       (flip-lists
        (for/list ([(pt ex) (in-pcontext (*pcontext*))])
          (list pt ex ((eval-prog `(λ ,vars ,expr) mode:fl) pt))))
       (for/list ([alt alts]) (map ulps->bits (alt-errors alt)))))
     < #:key third))

  ;; Next, we drop the points that are nan; we don't want them
  (define no-nan (filter-not (compose nan? third) table))
  (define no-dups
    (merge-duplicates
     no-nan #:key third
     (λ (a b) (list* (first a) (second a) (third a) (map + (drop a 3) (drop b 3))))))

  (define sis (err-lsts->split-indices (map (curryr drop 3) no-dups)))
  (define sps
    (for/list ([si sis])
      (define idx (si-pidx si))
      (sp (si-cidx si) expr
          (if (equal? idx (length no-dups)) #f (third (list-ref table idx))))))

  (define which-alt
    (for/list ([in (map third table)])
      (eprintf "~a : ~a\n" in sps)
      (for/first ([sp sps] #:when (or (not (sp-point sp)) (<= in (sp-point sp))))
        (sp-cidx sp))))

  (option sps
          (for/list ([alt-idx which-alt] [errs (flip-lists (drop table 3))])
            (list-ref errs alt-idx))))

#|
  (define merged-err-lsts (map (curry merge-err-lsts (map third table)) (drop bit-err-lsts 3)))
  (define split-indices (err-lsts->split-indices merged-err-lsts))
  (define split-points (sindices->spoints  expr alts split-indices))
  (option split-points (pick-errors split-points pts err-lsts vars)))
|#

(define (merge-duplicates lst f [same? equal?] #:key [key values])
  "Apply f to every pair of consecutive same? elements"
  (define-values (out last)
    (for/fold ([out '()] [last #f]) ([x lst])
      (define cur (key x))
      (if (and last (same? cur last))
          (values (cons (f (car out) x) (cdr out)) last)
          (values (cons x out) cur))))
  out)

#|
;; Accepts a list of sindices in one indexed form and returns the
;; proper splitpoints in floath form.
(define (sindices->spoints points expr alts sindices)
  (define (eval-on-pt pt)
    (let* ([expr-prog `(λ ,(program-variables (alt-program (car alts)))
			 ,expr)]
	   [val-float ((eval-prog expr-prog mode:fl) pt)])
      (if (ordinary-float? val-float) val-float
	  ((eval-prog expr-prog mode:bf) pt))))

  (define (sidx->spoint sidx next-sidx)
    (let* ([alt1 (list-ref alts (si-cidx sidx))]
	   [alt2 (list-ref alts (si-cidx next-sidx))]
	   [p1 (eval-on-pt (list-ref points (si-pidx sidx)))]
	   [p2 (eval-on-pt (list-ref points (sub1 (si-pidx sidx))))]
	   [eps (* (- p1 p2) *epsilon-fraction*)]
	   [pred (λ (v)
		   (let* ([start-prog* (replace-subexpr (*start-prog*) expr v)]
			  [prog1* (replace-subexpr (alt-program alt1) expr v)]
			  [prog2* (replace-subexpr (alt-program alt2) expr v)]
			  [context
			   (parameterize ([*num-points* (*binary-search-test-points*)])
			     (prepare-points start-prog* (map (curryr cons (eval-sampler 'default))
							      (program-variables start-prog*))))])
		     (< (errors-score (errors prog1* context))
			(errors-score (errors prog2* context)))))])
      (debug #:from 'regimes "searching between" p1 "and" p2 "on" expr)
      (sp (si-cidx sidx) expr (binary-search-floats pred p1 p2 eps))))


  (append
   (if ((flag 'reduce 'binary-search) #t #f)
       (map sidx->spoint
	    (take sindices (sub1 (length sindices)))
	    (drop sindices 1))
       (for/list ([sindex (take sindices (sub1 (length sindices)))])
	 (sp (si-cidx sindex) expr (eval-on-pt (list-ref points (si-pidx sindex))))))
   (list (let ([last-sidx (list-ref sindices (sub1 (length sindices)))])
	   (sp (si-cidx last-sidx)
	       expr
	       +inf.0)))))

(define (merge-err-lsts inps errs)
  (define errs* (for/list ([in inps] [err errs] #:when (not (nan? in))) err))
  (let loop ([in (car inps)] [inps (cdr inps)] [err (car errs*)] [errs (cdr errs*)])
    (if (null? inps)
        (list err)
        (if (equal? in (car inps))
            (loop in (cdr inps) (+ err (car errs)) (cdr errs))
            (cons err (loop (car inps) (cdr inps) (car errs) (cdr errs)))))))
|#

(define (point-with-dim index point val)
  (map (λ (pval pindex) (if (= pindex index) val pval))
       point
       (range (length point))))

(define (pick-errors splitpoints pts err-lsts variables)
  (reverse
   (first-value
    (for/fold ([acc '()] [rest-splits splitpoints])
	([pt (in-list pts)]
	 [errs (flip-lists err-lsts)])
      (let* ([expr-prog `(λ ,variables ,(sp-bexpr (car rest-splits)))]
	     [float-val ((eval-prog expr-prog mode:fl) pt)]
	     [pt-val (if (ordinary-float? float-val) float-val
			 ((eval-prog expr-prog mode:bf) pt))])
	(if (or (<= pt-val (sp-point (car rest-splits)))
		(and (null? (cdr rest-splits)) (nan? pt-val)))
	    (if (nan? pt-val) (error "wat")
		(values (cons (list-ref errs (sp-cidx (car rest-splits)))
			      acc)
			rest-splits))
	    (values acc (cdr rest-splits))))))))

(define (with-entry idx lst item)
  (if (= idx 0)
      (cons item (cdr lst))
      (cons (car lst) (with-entry (sub1 idx) (cdr lst) item))))

;; Takes a vector of numbers, and returns the partial sum of those numbers.
;; For example, if your vector is #(1 4 6 3 8), then this returns #(1 5 11 14 22).
(define (partial-sum vec)
  (first-value
   (for/fold ([res (make-vector (vector-length vec))]
	      [cur-psum 0])
       ([(el idx) (in-indexed (in-vector vec))])
     (let ([new-psum (+ cur-psum el)])
       (vector-set! res idx new-psum)
       (values res new-psum)))))

;; Struct represeting a splitpoint
;; cidx = Candidate index: the index of the candidate program that should be used to the left of this splitpoint
;; bexpr = Branch Expression: The expression that this splitpoint should split on
;; point = Split Point: The point at which we should split.
(struct sp (cidx bexpr point) #:prefab)

;; Struct representing a splitindex
;; cidx = Candidate index: the index candidate program that should be used to the left of this splitindex
;; pidx = Point index: The index of the point to the left of which we should split.
(struct si (cidx pidx) #:prefab)

;; Struct representing a candidate set of splitpoints that we are considering.
;; cost = The total error in the region to the left of our rightmost splitpoint
;; splitpoints = The splitpoints we are considering in this candidate.
(struct cse (cost splitpoints) #:transparent)

;; Given error-lsts, returns a list of sp objects representing where the optimal splitpoints are.
(define (err-lsts->split-indices err-lsts)
  ;; We have num-candidates candidates, each of whom has error lists of length num-points.
  ;; We keep track of the partial sums of the error lists so that we can easily find the cost of regions.
  (define num-candidates (length err-lsts))
  (define num-points (length (car err-lsts)))
  (define min-weight num-points)

  (define psums (map (compose partial-sum list->vector) err-lsts))

  ;; Our intermediary data is a list of cse's,
  ;; where each cse represents the optimal splitindices after however many passes
  ;; if we only consider indices to the left of that cse's index.
  ;; Given one of these lists, this function tries to add another splitindices to each cse.
  (define (add-splitpoint sp-prev)
    ;; If there's not enough room to add another splitpoint, just pass the sp-prev along.
    (for/list ([point-idx (in-naturals)] [point-entry (in-list sp-prev)])
      ;; We take the CSE corresponding to the best choice of previous split point.
      ;; The default, not making a new split-point, gets a bonus of min-weight
      (let ([acost (- (cse-cost point-entry) min-weight)] [aest point-entry])
        (for ([prev-split-idx (in-naturals)] [prev-entry (in-list (take sp-prev point-idx))])
          ;; For each previous split point, we need the best candidate to fill the new regime
          (let ([best #f] [bcost #f])
            (for ([cidx (in-naturals)] [psum (in-list psums)])
              (let ([cost (- (vector-ref psum point-idx)
                             (vector-ref psum prev-split-idx))])
                (when (or (not best) (< cost bcost))
                  (set! bcost cost)
                  (set! best cidx))))
            (when (< (+ (cse-cost prev-entry) bcost) acost)
              (set! acost (+ (cse-cost prev-entry) bcost))
              (set! aest (cse acost (cons (si best (+ point-idx 1))
                                          (cse-splitpoints prev-entry)))))))
        aest)))

  ;; We get the initial set of cse's by, at every point-index,
  ;; accumulating the candidates that are the best we can do
  ;; by using only one candidate to the left of that point.
  (define initial
    (for/list ([point-idx (in-range num-points)])
      (argmin cse-cost
              ;; Consider all the candidates we could put in this region
              (map (λ (cand-idx cand-psums)
                      (let ([cost (vector-ref cand-psums point-idx)])
                        (cse cost
                             (list (si cand-idx (add1 point-idx))))))
                         (range num-candidates)
                         psums))))

  ;; We get the final splitpoints by applying add-splitpoints as many times as we want
  (define final
    (let loop ([prev initial])
      (let ([next (add-splitpoint prev)])
        (if (equal? prev next)
            next
            (loop next)))))

  ;; Extract the splitpoints from our data structure, and reverse it.
  (reverse (cse-splitpoints (last final))))

(define (splitpoints->point-preds splitpoints num-alts)
  (let* ([expr (sp-bexpr (car splitpoints))]
	 [variables (program-variables (*start-prog*))]
	 [intervals (map cons (cons #f (drop-right splitpoints 1))
			 splitpoints)])
    (for/list ([i (in-range num-alts)])
      (let ([p-intervals (filter (λ (interval) (= i (sp-cidx (cdr interval)))) intervals)])
	(debug #:from 'splitpoints "intervals are: " p-intervals)
	(λ (p)
	  (let ([expr-val ((eval-prog `(λ ,variables ,expr) mode:fl) p)])
	    (for/or ([point-interval p-intervals])
	      (let ([lower-bound (if (car point-interval) (sp-point (car point-interval)) #f)]
		    [upper-bound (sp-point (cdr point-interval))])
		(and (or (not lower-bound) (lower-bound . < . expr-val))
		     (expr-val . <= . upper-bound))))))))))

(module+ test
  (parameterize ([*start-prog* '(λ (x y) (/ x y))])
    (define sps
      (list (sp 0 '(/ y x) -inf.0)
            (sp 2 '(/ y x) 0.0)
            (sp 1 '(/ y x) +inf.0)))
    (match-define (list p0? p1? p2?) (splitpoints->point-preds sps 3))

    (check-true (p0? '(0 -1)))
    (check-true (p2? '(-1 1)))
    (check-true (p1? '(+1 1)))))
