#|
 This file is a part of glsl-parser
 (c) 2017 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.trial.glsl.parser)

(defvar *unique-counter* 0)

(defun uniquify (&optional name)
  (format NIL "__~@[~a_~]~d" name *unique-counter*))

(defun matching-qualifiers-p (a b)
  (let ((irrelevant '(:highp :mediump :lowp :invariant :precise :smooth :flat :noperspective)))
    (null (set-difference
           (set-difference a irrelevant)
           (set-difference b irrelevant)
           :test #'equal))))

(defun matching-specifiers-p (a b)
  (null (set-difference a b :test #'equal)))

(defun matching-declarator-p (a b)
  (and (matching-qualifiers-p (first a) (first b))
       (matching-specifiers-p (second a) (second b))
       (equal (fourth a) (fourth a))))

(defun find-layout-qualifier (qualifiers)
  (find 'layout-qualifier qualifiers :key (lambda (a) (if (listp a) (first a) a))))

(defun pipeline-declaration-p (declaration)
  (and (consp (second declaration))
       (find-any '(:in :out :inout) (second declaration))))

;; See https://www.khronos.org/opengl/wiki/Shader_Compilation#Interface_matching
;; it has some notes on how variables are matched up between shader stages.
;; We imitate that behaviour, to a degree. We don't match up the same types,
;; as that would probably lead to confusing merges in most cases.
(defun handle-declaration (ast context environment global-env)
  (declare (ignore context))
  (unless (root-environment-p environment)
    (return-from handle-declaration ast))
  (flet ((store-identifier (from &optional (to from))
           (setf (gethash from global-env)
                 (if (gethash from global-env)
                     (uniquify to)
                     to))))
    (case (first ast)
      ((function-definition function-declaration)
       (store-identifier (fourth (second ast)))
       ast)
      (struct-declaration
       (store-identifier `(:struct ,(second ast)))
       ast)
      (precision-declaration
       ast)
      (variable-declaration
       (cond ((pipeline-declaration-p ast)
              (destructuring-bind (qualifiers specifiers identifier array &optional init) (rest ast)
                (cond ((find-layout-qualifier qualifiers)
                       (let ((matching (find (find-layout-qualifier qualifiers)
                                             (gethash 'declarations global-env)
                                             :test #'equal :key (lambda (a) (find-layout-qualifier (first a))))))
                         (cond ((not matching)
                                (push (rest ast) (gethash 'declarations global-env))
                                ast)
                               ((matching-declarator-p matching (rest ast))
                                (unless (equal init (fifth matching))
                                  (warn "Mismatched initializers between duplicate variable declarations:~%  ~a~%  ~a"
                                        (serialize `(variable-declaration ,@matching) NIL)
                                        (serialize ast NIL)))
                                (setf (gethash identifier global-env) (third matching))
                                (setf (binding identifier environment) (list :variable qualifiers specifiers array))
                                ;; We already have this declaration.
                                NIL)
                               (T
                                (error "Found two mismatched declarations with the same layout qualifier:~%  ~a~%  ~a"
                                       (serialize `(variable-declaration ,@matching) NIL)
                                       (serialize ast NIL))))))
                      ((gethash identifier global-env)
                       (let ((matching (find identifier
                                             (gethash 'declarations global-env)
                                             :test #'equal :key #'third)))
                         (cond ((matching-declarator-p matching (rest ast))
                                (unless (equal init (fifth matching))
                                  (warn "Mismatched initializers between duplicate variable declarations:~%  ~a~%  ~a"
                                        (serialize `(variable-declaration ,@matching) NIL)
                                        (serialize ast NIL)))
                                (setf (gethash identifier global-env) (third matching))
                                (setf (binding identifier environment) (list :variable qualifiers specifiers array))
                                ;; We /probably/ already have this declaration.
                                NIL)
                               (T
                                (warn "Found two mismatched declarations with the same identifier:~%  ~a~%  ~a"
                                      (serialize `(variable-declaration ,@matching) NIL)
                                      (serialize ast NIL))
                                (store-identifier identifier)
                                ast))))
                      (T
                       (push (rest ast) (gethash 'declarations global-env))
                       (store-identifier identifier)
                       ast))))
             (T
              (store-identifier (fourth ast))
              ast))))))

(defun handle-identifier (ast context environment global-env)
  (or (when (global-identifier-p ast environment)
        (if (eql 'struct-specifier (first context))
            (gethash `(:struct ,ast) global-env)
            (gethash ast global-env)))
      ast))

(defun split-shader-into-groups (shader)
  (let ((groups (list 'precision-declaration ()
                      'variable-declaration ()
                      'struct-declaration ()
                      'function-declaration ()
                      'function-definition ())))
    (flet ((walker (ast context environment)
             (declare (ignore context))
             (when (declaration-p ast environment)
               (push ast (getf groups (first ast))))
             ast))
      (walk shader #'walker))
    groups))

(defun merge-shaders (&rest shaders)
  (let ((*unique-counter* 0)
        (global-env (make-hash-table :test 'equal)))
    (flet ((walker (ast context environment)
             (cond ((declaration-p ast environment)
                    (handle-declaration ast context environment global-env))
                   ((stringp ast)
                    (handle-identifier ast context environment global-env))
                   (T
                    ast))))
      (append '(shader)
              (loop for shader in shaders
                    for *unique-counter* from 0
                    appending (rest (walk (parse shader) #'walker)))
              `((function-definition
                 (function-prototype
                  ,no-value :void "main")
                 (compound-statement
                  ,@(loop for shader in shaders
                          for *unique-counter* from 0
                          collect `(modified-reference ,(uniquify "main") (call-modifier))))))))))
