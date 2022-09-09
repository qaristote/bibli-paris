;; -*- lexical-binding: t -*-

(require 'request)
(require 'request-deferred)
(require 'concurrent)
(require 'deferred)
(require 'cl-lib)
(require 'org)
(require 'parse-csv)


;; constants

(defvar bibli-paris/default-library "75013 - Jean-Pierre Melville"
  "The default library from which to fetch updates.")

(defvar bibli-paris/central-library "75000 - Réserve centrale"
  "The name of the central library.")

(defvar bibli-paris/base-url
  "https://bibliotheques.paris.fr/"
  "The URL of the Parisian libraries' website.")

(defvar bibli-paris/holdings-api-url
  (concat bibli-paris/base-url "Default/Portal/Services/ILSClient.svc/GetHoldings")
  "The URL to which holdings request should be made.")

(defvar bibli-paris/base-entry-url
  (concat bibli-paris/base-url "Default/doc/SYRACUSE/")
  "The base URL of an entry's webpage.")

(defvar bibli-paris/max-async-requests
  250
  "The maximum number of concurrent requests.")

(defvar bibli-paris/async-requests-smp
  (cc:semaphore-create bibli-paris/max-async-requests)
  "The semaphore blocking too many concurrent requests.")

(defvar bibli-paris/request-timeout
  "1 sec"
  "The timeout of a request to the Paris' libaries API.")

(defvar bibli-paris/default-path-to-csv
  "~/Downloads/Export.csv"
  "The default path of a CSV file to import.")


;; utils

(defun bibli-paris/get-entry-author (&optional pom)
  "Return the record number of the entry located at POM (marker)."
  (org-entry-get pom "AUTEUR"))

(defun bibli-paris/get-entry-quotes(&optional pom)
  "Return the quotes of the entry located at POM (marker)."
  (org-entry-get pom "COTES"))

(defun bibli-paris/get-entry-recnum (&optional pom)
  "Return the record number of the entry located at POM (marker)."
  (org-entry-get pom "N°_DE_NOTICE"))

(defun bibli-paris/get-entry-title (&optional pom)
  "Return the title of the entry located at POM (marker)."
  (org-entry-get pom "TITRE"))


(defun bibli-paris/get-holding-quote (holding)
  "Return the quote associated with HOLDING (hash-tbl)."
  (gethash "Cote" holding))

(defun bibli-paris/get-holding-return-date (holding)
  "Return the return date associated with HOLDING (hash-tbl)."
  (gethash "WhenBack" holding))

(defun bibli-paris/get-holding-site (holding)
  "Return the site associated with HOLDING (hash-tbl)."
  (gethash "Site" holding))

(defun bibli-paris/get-holding-status (holding)
  "Return the status associated with HOLDING (hash-tbl)."
  (gethash "Statut" holding))

(defun bibli-paris/get-csv-recnum (csv-entry)
  "Return the record number contained in the CSV row CSV-ENTRY (string list)."
  (car (cdr csv-entry)))

(defun bibli-paris/get-csv-title (csv-entry)
  "Return the title contained in the CSV row CSV-ENTRY (string list)."
  (car csv-entry))

;;;###autoload
(defun bibli-paris/number-of-entries (&optional match scope)
  "Return the number of library entries selected by MATCH in SCOPE. See also the
[[https://orgmode.org/manual/Using-the-Mapping-API.html][Org mapping API]] for
more on MATCH and SCOPE."
  (interactive "sMatch : \nSScope : ")
  (let ((result (length
                 (org-map-entries (lambda () t)
                                  (unless (string-equal "" match)
                                    match)
                                  (unless (string-equal "" (symbol-name scope))
                                    scope)))))
    (message "%d" result)
    result))


;; sort entries

;;;###autoload
(defun bibli-paris/sort ()
  "Sort entries by their quotes, grouping them (hopefully) by series and author."
  (interactive)
  (save-excursion ; not working ?
    ;; select the whole buffer
    (set-mark (point-min))
    (goto-char (point-max))
    ;; run org-sort
    (org-sort-entries
     nil
     ?f
     ;; order entries by their quotes (the quote in the main
     ;; library having higher priority)
     #'(lambda () (save-excursion
                    (org-end-of-meta-data)
                    (forward-line)
                    (let ((main-quote (thing-at-point 'line t))
                          (other-quotes (bibli-paris/get-entry-quotes)))
                      (concat main-quote " " other-quotes)))))))


;; update entries
;; important for parallelism : most of these functions do not move the cursor

(defun bibli-paris/fetch-entry-holdings-by-id (recnum)
  "Given an entry specified by its record number RECNUM (string), return a
 deferred object that downloads JSON metadata on which libraries have the entry
 available."
  (deferred:$
    (deferred:nextc (cc:semaphore-acquire bibli-paris/async-requests-smp)
      (lambda ()
        (request-deferred bibli-paris/holdings-api-url
          :type "POST"
          :timeout bibli-paris/request-timeout
          :data (json-encode
                 `(,`("Record" .
                      ,`(("Docbase" . "Syracuse")
                         ,`("RscId" . ,recnum)))))
          :headers '(("Content-Type" . "application/json"))
          :encoding 'utf-8
          :parser (lambda ()
                    (let ((json-object-type 'hash-table)
                          (json-array-type 'list)
                          (json-key-type 'string))
                      (json-read))))))
    (deferred:nextc it
      (lambda (response)
        (progn
          (when response
            (cc:semaphore-release bibli-paris/async-requests-smp)
            (let ((error-thrown (request-response-error-thrown response)))
              (if error-thrown
                  (let ((error-symbol (car error-thrown))
                        (error-data (cdr error-thrown)))
                    (signal error-symbol error-data))
                (let* ((data (request-response-data response))
                       (d (gethash "d" data)))
                  (if d (gethash "Holdings" d) nil))))))))))


(defun bibli-paris/find-library-holding (holdings &optional library)
  "Find the holding data corresponding to the library LIBRARY (string) in
a list of holdings HOLDINGS (list of hash-tbls). If LIBRARY is nil,
BIBLI-PARIS/DEFAULT-LIBRARY is used."
  (seq-find (lambda (holding)
              (string-suffix-p (if library library bibli-paris/default-library)
                               (bibli-paris/get-holding-site holding)))
            holdings))

(defun bibli-paris/update-entry-schedule-from (holding)
  "Update entry schedule according to HOLDING (hash-tbl) the holding data of
the entry from a library.
The schedule is removed if the entry is marked as available, set to the return
date if borrowed and set to the maximum unix date if unavailable."
  (let* ((new-status (if holding (bibli-paris/get-holding-status holding) nil))
         (new-date (pcase new-status
                     ('"En rayon" nil)
                     ('"Emprunté"
                      (let* ((unformatted-date (bibli-paris/get-holding-return-date
                                                holding))
                             (day-month-year (split-string unformatted-date
                                                           "/")))
                        (apply 'format
                               "%3$s-%2$s-%1$s"
                               day-month-year)))
                     (_ "9999-12-31"))))
    (if new-date
        (org-schedule nil new-date)
      (org-schedule '(4)))))


(defun bibli-paris/clean-quote (entry-quote)
  "Remove extra whitespace from and uniformizes the quote QUOTE."
  (let ((blank "[[:blank:]\r\n]+")
        (result entry-quote))
    ;; "  " -> " "
    (setq result (replace-regexp-in-string blank " " result))
    ;; "$ " -> "$"
    (setq result (string-trim result blank blank))
    ;; "BD EN RESERVE" -> "EN RESERVE BD"
    (setq result (replace-regexp-in-string
                  "BD EN RESERVE" "EN RESERVE BD"
                  result t t))
    ;; "BD MANGA" -> "MANGA"
    (setq result (replace-regexp-in-string
                  "BD MANGA" "MANGA"
                  result t t))
    ;; "BD COMICS" -> "COMICS"
    (setq result (replace-regexp-in-string
                  "BD COMICS" "COMICS"
                  result t t))
    ;; "1" -> "01"
    (setq result (replace-regexp-in-string
                  "\\([^0-9/]\\)\\([0-9]\\)\\($\\|\/\\| \\)"
                  "\\10\\2\\3"
                  result))
    result))

(defun bibli-paris/update-entry-quote-from (holding)
  "Update entry quote according to HOLDING (hash-tbl) the holding data of the
entry from a library."
  (let ((new-quote (if holding
                       (bibli-paris/clean-quote (bibli-paris/get-holding-quote holding))
                     "unavailable"))
        (begin) (end))
    (save-excursion
      (org-back-to-heading)
      (org-end-of-meta-data)
      (when new-quote
        (newline)
        (insert new-quote)
        (newline))
      (setq begin (point))
      (org-next-visible-heading 1)
      (setq end (point))
      (delete-region begin end)
      (newline)
      (message "Set quote to \"%s\"" new-quote)
      )))

(defun bibli-paris/update-availability-at-central-library (holdings)
  "Update entry tags according to whether it is held in HOLDINGS (hash-tbl list)
at the central library."
  (org-toggle-tag "RéserveCentrale"
                  (if (seq-some
                       (lambda (holding)
                         (string-suffix-p bibli-paris/central-library
                                          (bibli-paris/get-holding-site holding)))
                       holdings)
                      'on 'off)))

(defun bibli-paris/update-entry-from (holdings)
  "Update the entry at point using its holdings HOLDINGS (hash-tbl list)."
  (let ((holding (if holdings
                     (bibli-paris/find-library-holding holdings)
                   nil)))
    (message "(bibli-paris) Updating %s (%s) ..." (bibli-paris/get-entry-title) (bibli-paris/get-entry-author))
    (bibli-paris/update-entry-schedule-from holding)
    (bibli-paris/update-entry-quote-from holding)
    (bibli-paris/update-availability-at-central-library holdings)))

;;;###autoload
(defun bibli-paris/update-entry ()
  "Update the schedule and quote of the entry at point."
  (interactive)
   (deferred:$
     (deferred:call 'message
       "(bibli-paris) Fetching holdings for %s (%s) ..."
       (bibli-paris/get-entry-title)
       (bibli-paris/get-entry-author))
     (bibli-paris/fetch-entry-holdings-by-id (bibli-paris/get-entry-recnum))
     (deferred:nextc it 'bibli-paris/update-entry-from)))

(defun bibli-paris/update-entries-async (&optional match scope)
    (deferred:$
      (deferred:call 'message "(bibli-paris) Fetching holdings ...")
      (deferred:parallel
        (org-map-entries
         (lambda ()
           (let ((recnum (bibli-paris/get-entry-recnum))
                 (title (bibli-paris/get-entry-title))
                 (author (bibli-paris/get-entry-author)))
             (deferred:$
               (bibli-paris/fetch-entry-holdings-by-id recnum)
               (deferred:nextc it
                 (lambda (x)
                   (progn
                     (message "(bibli-paris) Fetched holdings for %s (%s)."
                              title author))
                   x)))))
         match scope))
      (deferred:nextc it
        (lambda (holdings-seq)
           (org-map-entries (lambda ()
                              (let ((holdings (pop holdings-seq)))
                                (bibli-paris/update-entry-from holdings)))
                            match scope)))
      (deferred:nextc it
        (lambda () (message "(bibli-paris) Update complete.")))))

(defun bibli-paris/update-entries-sequential (&optional match scope)
  "Update all entries' schedules and quotes, fetching the corresponding data
sequentially. Terribly inefficient but works."
  (org-map-entries 'bibli-paris/update-entry match scope))

;;;###autoload
(defun bibli-paris/update-region ()
  "Update the schedules and quotes of the entries in the current region."
  (interactive)
  (bibli-paris/update-entries-async nil 'region))

;;;###autoload
(defun bibli-paris/update-buffer ()
  "Update the schedules and quotes of the entries in the current buffer, and
sort it afterwards."
  (interactive)
  (bibli-paris/update-entries-async)
  (bibli-paris/sort))


;; import entries

(defun bibli-paris/insert-csv-entry (keys row &optional tags state old)
  "Insert at point a new entry described by a list of keys KEYS and associated
values in ROW, and set the tags TAGS (string seq) and the state STATE (string
that defaults to TODO.). If OLD is not nil, only update the properties and tags
without inserting the heading."
  (let* ((title (bibli-paris/get-csv-title row))
         (recnum (bibli-paris/get-csv-recnum row))
         (heading (format "* %s [[%s][%s]]"
                          (if state state "TODO")
                          (concat bibli-paris/base-entry-url recnum)
                          title)))
    (unless old
      (newline)
      (insert heading))
    (cl-mapc (lambda (key value)
               (let ((formatted-key (upcase
                                     (replace-regexp-in-string " " "_"
                                                               key)))
                     (formatted-value (string-trim value)))
                 (if (not (string-equal formatted-value ""))
                     (org-set-property formatted-key formatted-value))))
             keys row)
    (when (not (string-equal tags "")) (org-toggle-tag tags 'on))))

(defun bibli-paris/insert-or-update-csv-entries (keys rows recnum-lines
                                                      &optional tags state)
  "Insert entries described by a list of keys KEYS and associated to values in
ROW at the end of the buffer. Also set the tags TAGS (string seq) and the state
STATE (string that defaults to TODO.). If an entry has a record number found in
RECNUM-POMS (string to marker hash table), only update the entry at
corresponding point (without inserting the heading)."
  ;; TODO : remove race conditions
  (seq-do (lambda (row)
            (when-let (recnum (bibli-paris/get-csv-recnum row))
              (save-excursion
                (if-let (line (gethash recnum recnum-lines))
                    (progn
                      (goto-char (point-min))
                      (org-next-visible-heading line)
                      (message "Updating %s (%s) ..."
                               (bibli-paris/get-entry-title)
                               (bibli-paris/get-entry-author)))
                  (goto-char (point-max))
                  (message "Inserting %s (%s) ..."
                           (bibli-paris/get-entry-title)
                           (bibli-paris/get-entry-author))
                  (bibli-paris/insert-csv-entry keys row tags state line)
              ))))
          rows))

(defun bibli-paris/parse-csv (path-to-csv)
  "Load a CSV file from PATH-TO-CSV (string) into a list of rows, each row being
being encoded as a list of strings."
  (let* ((csv-buffer (generate-new-buffer "bibli-paris/csv-to-import-from"))
         (result (save-current-buffer
                   (set-buffer csv-buffer)
                   (insert-file-contents path-to-csv)
                   (parse-csv-string-rows (buffer-string) ?\; ?\" "\n"))))
    (kill-buffer csv-buffer)
    result))

;;;###autoload
(defun bibli-paris/import-from-csv (&optional path-to-csv tags state)
  "Import entries from the CSV file downloaded on
https://bibliotheques.paris.fr/ whose path is given by PATH-TO-CSV (string).
New entries are inserted at the end of the buffer and the other entries are
updated.
All the imported entries are set with the tag TAGS (string) and in the state
STATE (string)."
  (interactive (list (read-file-name "Import from : "
                                     nil
                                     nil
                                     nil
                                     bibli-paris/default-path-to-csv)
                     (read-string "Tags : ")
                     (read-string "State : "
                                  "TODO")))
  (let* ((recnum-lines (make-hash-table :test 'equal
                                         :size (bibli-paris/number-of-entries)
                                         :weakness 'key-and-value))
          (path-to-csv (if path-to-csv path-to-csv bibli-paris/default-path-to-csv))
          (csv-rows (bibli-paris/parse-csv path-to-csv))
          (entry-number 0))
    (message "Importing library entries from %s ..." path-to-csv)
    (org-map-entries (lambda ()
                       (puthash (bibli-paris/get-entry-recnum) entry-number recnum-lines)
                       (setq entry-number (1+ entry-number))))
    (bibli-paris/insert-or-update-csv-entries (car csv-rows)
                                              (cdr csv-rows)
                                              recnum-lines
                                              tags
                                              state))
  (message "Import done."))


;; archive entries

;;;###autoload
(defun bibli-paris/archive-all-read ()
  "Archive all entries in the DONE state."
  (interactive)
  (org-map-entries (lambda ()
                     (when (equal (org-get-todo-state) "DONE")
                       ;; archiving an entry moves the cursor to next entry
                       ;; so we move it back to the previous entry
                       (org-archive-subtree)
                       (setq org-map-continue-from (outline-get-last-sibling))
                       ))))


;; move between entries

(defun bibli-paris/change-entry (move-fun)
  "Run the MOVE-FUN function and put forward the resulting entry at point."
  (org-hide-entry)
  (funcall move-fun)
  (org-show-subtree)
  (recenter 5))

;;;###autoload
(defun bibli-paris/previous-entry ()
  "Move to and put forward the previous entry."
  (interactive)
  (bibli-paris/change-entry 'outline-get-last-sibling))

;;;###autoload
(defun bibli-paris/next-entry ()
  "Move to and put forward the next entry."
  (interactive)
  (bibli-paris/change-entry 'outline-get-next-sibling))


;; change the state of an entry

;;;###autoload
(defun bibli-paris/set-to-todo ()
  "Switch the entry at point to the TODO state."
  (interactive)
  (org-todo "TODO"))

;;;###autoload
(defun bibli-paris/set-to-next ()
  "Switch the entry at point to the NEXT state."
  (interactive)
  (org-todo "NEXT"))

;;;###autoload
(defun bibli-paris/set-to-booked ()
  "Switch the entry at point to the BOOKED state."
  (interactive)
  (org-todo "BOOKED"))

;;;###autoload
(defun bibli-paris/set-to-done ()
  "Switch the entry at point to the DONE state."
  (interactive)
  (org-todo "DONE"))


;; minor mode

;;;###autoload
(define-minor-mode bibli-paris/mode
  "Manage reading lists of documents available in Paris' libraries."
  :lighter "bibli-paris")

(add-hook 'find-file-hook
          (lambda ()
            (when (and (string-suffix-p "Bibliothèques de Paris/" (file-name-directory buffer-file-name))
                       (string-prefix-p "org" (file-name-extension buffer-file-name)))
              (bibli-paris/mode +1))))


(provide 'bibli-paris)
