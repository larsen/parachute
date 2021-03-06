#|
 This file is a part of parachute
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.parachute)

(defvar *parent* NIL)
(defvar *context* NIL)

(defmethod eval-in-context :around (context thing)
  (let ((*context* context))
    (call-next-method)))

(defmethod result-for-testable ((test test) context)
  (make-instance 'test-result :expression test))

(defclass result ()
  ((expression :initarg :expression :accessor expression)
   (status :initarg :status :accessor status)
   (duration :initarg :duration :accessor duration)
   (description :initarg :description :accessor description))
  (:default-initargs
   :expression (error "EXPRESSION required.")
   :status :unknown
   :duration NIL
   :description NIL))

(defmethod initialize-instance :after ((result result) &key)
  (when *parent* (add-result result *parent*))
  (when *context* (add-result result *context*)))

(defmethod print-object ((result result) stream)
  (print-unreadable-object (result stream :type T)
    (format stream "~s ~a" (status result) (format-result result :oneline))))

(defmethod format-result ((result result) (type (eql :oneline)))
  (print-oneline (expression result) NIL))

(defmethod format-result ((result result) (type (eql :extensive)))
  (format NIL "Test for ~a ~(~a~).~@[~%~a~]"
          (expression result) (status result)
          (description result)))

(defmethod eval-in-context :around (context (result result))
  ;; Unless the status is unknown marked we should probably skip.
  (when (eql :unknown (status result))
    (let ((start (get-internal-real-time)))
      (unwind-protect
           (call-next-method)
        (setf (duration result) (/ (- (get-internal-real-time) start)
                                   internal-time-units-per-second))))
    ;; Mark ourselves as passed if we didn't already set the status.    
    (when (eql :unknown (status result))
      (setf (status result) :passed))))

(defclass value-result (result)
  ((value :initarg :value :accessor value)
   (body :initarg :body :accessor body))
  (:default-initargs
   :body (error "BODY required.")))

(defmethod eval-in-context (context (result value-result))
  (unless (slot-boundp result 'value)
    (setf (value result) (typecase (body result)
                           (function (funcall (body result)))
                           (T (body result))))))

(defclass finishing-result (value-result)
  ())

(defmethod eval-in-context (context (result finishing-result))
  (unwind-protect
       (progn (call-next-method)
              (setf (status result) :passed))
    (unless (eql :passed (status result))
      (setf (status result) :failed))))

(defclass comparison-result (value-result)
  ((value-form :initarg :value-form :accessor value-form)
   (expected :initarg :expected :accessor expected)
   (comparison :initarg :comparison :accessor comparison)
   (comparison-geq :initarg :comparison-geq :accessor comparison-geq))
  (:default-initargs
   :value-form :unknown
   :expected '(not null)
   :comparison 'typep
   :comparison-geq T))

(defmethod format-result ((result comparison-result) (type (eql :extensive)))
  (let ((*print-right-margin* 600))
    (format NIL "The test form   ~a~%~
                 evaluated to    ~a~%~
                 when            ~a~%~
                 was expected to be ~:[unequal~;equal~] under ~a.~@[~%~a~]"
            (print-oneline (value-form result) NIL)
            (if (slot-boundp result 'value)
                (value result)
                (gensym "UNBOUND"))
            (print-oneline (expected result) NIL)
            (comparison-geq result)
            (comparison result)
            (description result))))

(defmethod eval-in-context (context (result comparison-result))
  (call-next-method)
  (when (eql :unknown (status result))
    (if (ignore-errors (geq (funcall (comparison result)
                                     (value result)
                                     (expected result))
                            (comparison-geq result)))
        (setf (status result) :passed)
        (setf (status result) :failed))))

(defclass parent-result (result)
  ((results :initform (make-array 0 :adjustable T :fill-pointer T) :accessor results)))

(defmethod result-for-testable ((test test) (result parent-result))
  (or (find-child-result test result)
      (call-next-method)))

(defmethod eval-in-context :around (context (result parent-result))
  (let ((*parent* result))
    (call-next-method)))

(defmethod eval-in-context :after (context (result parent-result))
  (when (loop for child across (results result)
              thereis (eql :failed (status child)))
    (setf (status result) :failed)))

(defmethod find-child-result (test (result parent-result))
  (find test (results result) :key #'expression :test #'eq))

(defmethod results-with-status (status (result parent-result))
  (loop for result across (results result)
        when (eql status (status result))
        collect result))

(defmethod add-result ((result result) (parent parent-result))
  (unless (find result (results parent))
    (vector-push-extend result (results parent))))

(defclass test-result (parent-result)
  ())

(defmethod format-result ((result test-result) (type (eql :oneline)))
  (format NIL "~a::~a"
          (package-name (home (expression result)))
          (name (expression result))))

(defmethod format-result ((result test-result) (type (eql :extensive)))
  (format NIL "~4d/~4d tests failed in ~a~@[~%~a~]"
          (length (results-with-status :failed result)) (length (results result))
          (format-result result :oneline)
          (description result)))

(defmethod eval-in-context :around (context (result test-result))
  ;; We have to run the dependencies here as they need to run before
  ;; the timing grips in the AROUND method of the RESULT class for
  ;; EVAL-IN-CONTEXT, which would count them running in a BEFORE.
  (eval-dependency-combination context (dependencies (expression result)))
  (call-next-method)
  (let ((test (expression result)))
    (when (and (time-limit test)
               (< (time-limit test)
                  (duration result)))
      (setf (description result)
            (format NIL "The limit of ~fs was exceeded as the test took ~fs to run."
                    (time-limit test) (duration result)))
      (setf (status result) :failed))))

(defmethod eval-in-context (context (result test-result))
  (let* ((test (expression result))
         (result (result-for-testable test context))
         (skipped (skipped-children test)))
    (setf (description result) (description test))
    (cond ((check-dependency-combination :passed context (dependencies test))
           (eval-in-context context test))
          (T
           (setf (status result) :skipped)))
    (loop for child in (children test)
          for subresult = (result-for-testable child context)
          do (cond ((find child skipped)
                    (setf (status child) :skipped)
                    (eval-in-context context subresult))
                   (T
                    (eval-in-context context subresult))))))

;; This is a hack, oh boy.
(defvar *real-context* NIL)

(defclass controlling-result (parent-result)
  ((child-status :initarg :child-status :accessor child-status)
   (body :initarg :body :accessor body)))

(defmethod eval-in-context (context (result controlling-result))
  (let ((*real-context* context)
        (*context* result))
    (funcall (body result))))

(defmethod eval-in-context :after (context (result controlling-result))
  (setf (status result) :passed))

(defmethod eval-in-context :before ((context controlling-result) (result result))
  (add-result result *real-context*))

(defmethod eval-in-context ((context controlling-result) (result value-result))
  (setf (body result) (lambda () (setf (status result) (child-status context))))
  (eval-in-context *real-context* result)
  (slot-makunbound result 'value))

(defmethod format-result ((result controlling-result) (type (eql :oneline)))
  (format NIL "~a~@[: ~a~]"
          (case (child-status result) (:skipped :skip) (:failed :fail) (:passed :pass) (T (child-status result)))
          (description result)))
