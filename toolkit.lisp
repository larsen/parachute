#|
 This file is a part of parachute
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.parachute)

(defun shuffle (seq)
  (let ((seq (copy-seq seq))
        (len (length seq)))
    (dotimes (i len seq)
      (let ((r (+ i (random (- len i)))))
        (rotatef (elt seq i) (elt seq r))))))

(defmacro with-shuffling (&body body)
  (let ((thunk (gensym "THUNK")))
    `(dolist (,thunk (shuffle
                      (list ,@(loop for form in body
                                    collect `(lambda () ,form)))))
       (funcall ,thunk))))

(defun removef (place &rest indicators)
  (loop for (k v) on place by #'cddr
        for found = (find k indicators)
        unless found collect k
        unless found collect v))

(defun locked-package-p (package)
  #+sbcl (sb-ext:package-locked-p package)
  #-sbcl (eql (find-package :cl) package))

(defun print-oneline (thing &optional (output T))
  (typecase output
    ((eql T)   (print-oneline thing *standard-output*))
    ((eql NIL) (with-output-to-string (o)
                 (print-oneline thing o)))
    (stream
     (typecase thing
       (null (format output "()"))
       (cons
        (cond ((eql 'quote (first thing))
               (format output "'")
               (print-oneline (second thing) output))
              (T
               (format output "(")
               (loop for (car . cdr) on thing
                     do (print-oneline car output)
                        (typecase cdr
                          (null)
                          (cons (format output " "))
                          (T (format output " . ")
                           (print-oneline cdr output))))
               (format output ")"))))
       (string (prin1 thing output))
       (vector (format output "#(")
        (loop for i from 0 below (length thing)
              do (print-oneline (aref thing i))
                 (when (< i (1- (length thing)))
                   (format output " ")))
        (format output ")"))
       (T (princ thing output))))))

(defun geq (value expected)
  (if expected
      value
      (not value)))

(defmacro capture-error (form &optional (condition 'error))
  (let ((err (gensym "ERR")))
    `(handler-case
         (prog1 NIL ,form)
       (,condition (,err)
         ,err))))

(defun maybe-quote (expression)
  (typecase expression
    (list (case (first expression)
            ((quote lambda function #+sbcl sb-int:quasiquote #+ecl si:quasiquote)
             expression)
            (T `',expression)))
    (T (if (constantp expression)
           expression
           `',expression))))

(defun maybe-unquote (expression)
  (typecase expression
    (cons
     ;; We assume that this is a form that'll produce an unquoted value
     ;; either by being a direct quote or by being quasiquoted in some
     ;; implementation-defined manner. Either way, evaluating it should
     ;; yield our value. Naturally this will fail if it needs to reference
     ;; lexical variables.
     (handler-case (eval expression)
       (error (err)
         (error "Failed to unquote ~s. You probably have lexical variables that can't be resolved.~%~
                 The actual error said: ~a"
                expression err))))
    (T expression)))

(defun call-compile (form)
  (handler-bind (((or warning #+sbcl sb-ext:compiler-note) #'muffle-warning))
    (funcall (compile NIL `(lambda () ,form)))))
