#lang racket
(require casio/test)

; Weak limit of the three-state quantum walk on the line
; S. Falkner and S. Boettcher
; Phys. Rev. A, 012307 (2014), http://link.aps.org/doi/10.1103/PhysRevA.90.012307

(casio-bench (v t)
  "Falkner and Boettcher, Equation (20:1,3)"
  (/ (- 1 (* 5 (sqr v))) (* 3.141592653589793 t (sqrt (* 2 (- 1 (* 3 (sqr v))))) (- 1 (sqr v)))))

(casio-bench (v)
  "Falkner and Boettcher, Equation (22+)"
  (let* ([pi 3.141592653589793])
    (/ 4 (* 3 pi (- 1 (sqr v)) (sqrt (- 2 (* 6 (sqr v))))))))

(casio-bench (a k m)
  "Falkner and Boettcher, Appendix A"
  (/ (* a (expt k m)) (+ 1 (* 10 k) (sqr k))))

(casio-bench (v)
  "Falkner and Boettcher, Appendix B, 1"
  (acos (/ (- 1 (* 5 (sqr v))) (- (sqr v) 1))))

(casio-bench (v)
  "Falkner and Boettcher, Appendix B, 2"
  (* (/ (sqrt 2) 4) (sqrt (- 1 (* 3 (sqr v)))) (- 1 (sqr v))))