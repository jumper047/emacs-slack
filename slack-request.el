;;; slack-request.el ---slack request function       -*- lexical-binding: t; -*-

;; Copyright (C) 2015  南優也

;; Author: 南優也 <yuyaminami@minamiyuunari-no-MacBook-Pro.local>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'subr-x)
(require 'eieio)
(require 'json)
(require 'request)
(require 'slack-util)
(declare-function slack-team-token "slack-team")
(require 'slack-log)

(defcustom slack-request-timeout 10
  "Request Timeout in seconds."
  :type 'integer
  :group 'slack)

(defun slack-parse ()
  (let ((json-object-type 'plist)
        (json-array-type 'list))
    (json-read)))

(defun slack-request-parse-payload (payload)
  (let ((json-object-type 'plist)
        (json-array-type 'list))
    (condition-case err-var
        (json-read-from-string payload)
      (error (message "[Slack] Error on parse JSON: %S, ERR: %S"
                      payload
                      err-var)
             nil))))

(defclass slack-request-request ()
  ((response :initform nil)
   (url :initarg :url)
   (team :initarg :team)
   (type :initarg :type :initform "GET")
   (success :initarg :success)
   (error :initarg :error :initform nil)
   (params :initarg :params :initform nil)
   (data :initarg :data :initform nil)
   (parser :initarg :parser :initform #'slack-parse)
   (sync :initarg :sync :initform nil)
   (files :initarg :files :initform nil)
   (headers :initarg :headers :initform nil)
   (timeout :initarg :timeout :initform `,slack-request-timeout)
   (execute-at :initform 0.0 :type float)))

(cl-defun slack-request-create
    (url team &key type success error params data parser sync files headers timeout)
  (let ((args (list
               :url url :team team :type type
               :success success :error error
               :params params :data data :parser parser
               :sync sync :files files :headers headers
               :timeout timeout))
        (ret nil))
    (mapc #'(lambda (maybe-key)
              (let ((value (plist-get args maybe-key)))
                (when value
                  (setq ret (plist-put ret maybe-key value)))))
          args)
    (apply #'make-instance 'slack-request-request ret)))

(cl-defmethod slack-equalp ((this slack-request-request) other)
  (and (slack-equalp (oref this team)
                     (oref other team))
       (string= "GET" (oref this type))
       (string= "GET" (oref other type))
       (string= (oref this url)
                (oref other url))
       (equal (oref this params)
              (oref other params))))

(cl-defmethod slack-request-retry-request ((req slack-request-request) retry-after)
  (oset req execute-at (+ retry-after (time-to-seconds)))
  (slack-request-worker-push req))

(cl-defmethod slack-request-retry-failed-request-p ((req slack-request-request) error-thrown symbol-status)
  (with-slots (type) req
    (and (string= type "GET")
         (or (and error-thrown
                  (eq 'end-of-file (car error-thrown)))
             (eq symbol-status 'timeout)))))

(cl-defmethod slack-request ((req slack-request-request)
                             &key (on-success nil) (on-error nil))
  (let ((team (oref req team)))
    (with-slots (url type success error params data parser sync files headers timeout) req
      (cl-labels
          ((on-success (&key data &allow-other-keys)
                       (funcall success :data data)
                       (slack-log
                        (format "Request Finished. URL: %s, PARAMS: %s"
                                url
                                params)
                        team :level 'trace)
                       (when (functionp on-success)
                         (funcall on-success)))
           (on-error (&key error-thrown symbol-status response data)
                     (slack-if-let* ((retry-after (request-response-header response "retry-after"))
                                     (retry-after-sec (string-to-number retry-after)))
                         (progn
                           (slack-request-retry-request req retry-after-sec)
                           (slack-log (format "Retrying Request After: %s second, URL: %s, PARAMS: %s"
                                              retry-after-sec
                                              url
                                              params)
                                      team))
                       (slack-log (format "REQUEST FAILED. URL: %S, PARAMS: %S, ERROR-THROWN: %S, SYMBOL-STATUS: %S, DATA: %S"
                                          url
                                          params
                                          error-thrown
                                          symbol-status
                                          data)
                                  team :level 'error)
                       (if (slack-request-retry-failed-request-p req error-thrown symbol-status)
                           (progn
                             (slack-log (format "Retry Requst by Error. URL: %S, PARAMS: %S, ERROR-THROWN: %S, SYMBOL-STATUS: %S, DATA: %S"
                                                url
                                                params
                                                error-thrown
                                                symbol-status
                                                data)
                                        team :level 'warn)
                             (slack-request-retry-request req 1))
                         (when (functionp error)
                           (funcall error
                                    :error-thrown error-thrown
                                    :symbol-status symbol-status
                                    :response response
                                    :data data))
                         (when (functionp on-error)
                           (funcall on-error))))))
        (oset req response
              (request
               url
               :type type
               :sync sync
               :params (cons (cons "token" (slack-team-token team))
                             params)
               :data data
               :files files
               :headers headers
               :parser parser
               :success #'on-success
               :error #'on-error
               :timeout timeout))))))


(cl-defmacro slack-request-handle-error ((data req-name &optional handler) &body body)
  "Bind error to e if present in DATA."
  `(if (eq (plist-get ,data :ok) :json-false)
       (if ,handler
           (funcall ,handler (plist-get ,data :error))
         (message "Failed to request %s: %s"
                  ,req-name
                  (plist-get ,data :error)))
     (progn
       ,@body)))

;; Request Worker

(defcustom slack-request-worker-max-request-limit 30
  "Max request count perform simultaneously."
  :type 'integer
  :group 'slack)

(defvar slack-request-worker-instance nil)

(defclass slack-request-worker ()
  ((queue :initform '() :type list)
   (timer :initform nil)
   (current-request-count :initform 0 :type integer)
   ))

(defun slack-request-worker-create ()
  "Create `slack-request-worker' instance."
  (make-instance 'slack-request-worker))

(cl-defmethod slack-request-worker-push ((this slack-request-worker) req)
  (cl-pushnew req (oref this queue) :test #'slack-equalp))

(defun slack-request-worker-set-timer ()
  (cl-labels
      ((on-timeout ()
                   (slack-request-worker-execute)
                   (when (timerp slack-request-worker-instance)
                     (cancel-timer slack-request-worker-instance))
                   (slack-request-worker-set-timer)))
    (oset slack-request-worker-instance timer
          (run-at-time 1 nil #'on-timeout))))

(defun slack-request-worker-execute ()
  "Pop request from queue until `slack-request-worker-max-request-limit', and execute."
  (when slack-request-worker-instance
    (let ((do '())
          (skip '())
          (current (time-to-seconds))
          (limit (- slack-request-worker-max-request-limit
                    (oref slack-request-worker-instance
                          current-request-count))))

      (cl-loop for req in (reverse (oref slack-request-worker-instance queue))
               do (if (and (< (oref req execute-at) current)
                           (< (length do) limit))
                      (push req do)
                    (push req skip)))

      ;; (message "[WORKER] QUEUE: %s, LIMIT: %s, CURRENT: %s, DO: %s, SKIP: %s"
      ;;          (length (oref slack-request-worker-instance queue))
      ;;          slack-request-worker-max-request-limit
      ;;          (oref slack-request-worker-instance current-request-count)
      ;;          (length do)
      ;;          (length skip))

      (oset slack-request-worker-instance queue skip)

      (cl-labels
          ((decl-request-count
            ()
            (cl-decf (oref slack-request-worker-instance
                           current-request-count))))
        (cl-loop for req in do
                 do (progn
                      (cl-incf (oref slack-request-worker-instance
                                     current-request-count))
                      (slack-request req
                                     :on-success #'decl-request-count
                                     :on-error #'decl-request-count
                                     )))))))

(cl-defmethod slack-request-worker-push ((req slack-request-request))
  (unless slack-request-worker-instance
    (setq slack-request-worker-instance
          (slack-request-worker-create)))
  (slack-request-worker-push slack-request-worker-instance req)
  (unless (oref slack-request-worker-instance timer)
    (slack-request-worker-set-timer)))

(defun slack-request-worker-quit ()
  "Cancel timer and remove `slack-request-worker-instance'."
  (when (and slack-request-worker-instance
             (timerp (oref slack-request-worker-instance timer)))
    (cancel-timer (oref slack-request-worker-instance timer)))
  (setq slack-request-worker-instance nil))

(defun slack-request-worker-remove-request (team)
  "Remove request from TEAM in queue."
  (when slack-request-worker-instance
    (let ((to-remove '())
          (new-queue '())
          (all (oref slack-request-worker-instance queue)))

      (dolist (req all)
        (if (slack-equalp (oref req team) team)
            (push req to-remove)
          (push req new-queue)))

      (dolist (req to-remove)
        (when (and (oref req response)
                   (not (request-response-done-p (oref req response))))
          (request-abort (oref req response))))

      (oset slack-request-worker-instance queue new-queue)
      (slack-log (format "Remove Request from Worker, ALL: %s, REMOVED: %s, NEW-QUEUE: %s"
                         (length all)
                         (length to-remove)
                         (length new-queue))
                 team :level 'debug))))

(cl-defun slack-url-copy-file (url newname &key (success nil) (error nil) (sync nil) (token nil))
  (if (executable-find "curl")
      (slack-curl-downloader url newname
                             :success success
                             :error error
                             :token token)
    (cl-labels
        ((on-success (&key _data &allow-other-keys)
                     (when (functionp success) (funcall success)))
         (on-error (&key error-thrown symbol-status response _data)
                   (message "Error Fetching Image: %s %s %s, url: %s"
                            (request-response-status-code response)
                            error-thrown symbol-status url)
                   (if (file-exists-p newname)
                       (delete-file newname))
                   (cl-case (request-response-status-code response)
                     (403 nil)
                     (404 nil)
                     (t (when (functionp error)
                          (funcall error
                                   (request-response-status-code response)
                                   error-thrown
                                   symbol-status
                                   url)))))
         (parser () (mm-write-region (point-min) (point-max)
                                     newname nil nil nil 'binary t)))
      (let* ((url-obj (url-generic-parse-url url))
             (need-token-p (and url-obj
                                (string-match-p "slack"
                                                (url-host url-obj))))
             (use-https-p (and url-obj
                               (string= "https" (url-type url-obj)))))
        (request
         url
         :success #'on-success
         :error #'on-error
         :parser #'parser
         :sync sync
         :headers (if (and token use-https-p need-token-p)
                      (list (cons "Authorization" (format "Bearer %s" token)))))))))

(cl-defun slack-curl-downloader (url name &key (success nil) (error nil) (token nil))
  (cl-labels
      ((sentinel (proc event)
                 (cond
                  ((string-equal "finished\n" event)
                   (when (functionp success) (funcall success)))
                  (t
                   (let ((status (process-status proc))
                         (output (with-current-buffer (process-buffer proc)
                                   (buffer-substring-no-properties (point-min)
                                                                   (point-max)))))
                     (if (functionp error)
                         (funcall error status output url name)
                       (message "Download Failed. STATUS: %s, EVENT: %s, URL: %s, NAME: %s, OUTPUT: %s"
                                status
                                event
                                url
                                name
                                output))
                     (if (file-exists-p name)
                         (delete-file name))
                     (delete-process proc))))))
    (let* ((url-obj (url-generic-parse-url url))
           (need-token-p (and url-obj
                              (string-match-p "slack" (url-host url-obj))))
           (header (or (and token
                            need-token-p
                            (string-prefix-p "https" url)
                            (format "-H 'Authorization: Bearer %s'" token))
                       ""))
           (output (format "--output '%s'" name))
           (command (format "curl --silent --show-error --fail --location %s %s '%s'" output header url))
           (proc (start-process-shell-command "slack-curl-downloader"
                                              "slack-curl-downloader"
                                              command)))
      (set-process-sentinel proc #'sentinel))))

(provide 'slack-request)
;;; slack-request.el ends here
