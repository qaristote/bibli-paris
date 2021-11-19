(require 'request)
(require 'request-deferred)
(require 'deferred)
(require 'cl-lib)
(require 'subr-x)
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

(defvar bibli-paris/max-asynchronous-processes
  500
  "The maximum number of asynchronous processes that can be launched by Emacs.
   Determined experimentally.")

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
(defun bibli-paris/number-of-entries ()
  "Return the number library entries in the current buffer."
  (interactive)
  (length (org-map-entries (lambda () t))))


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
    (org-sort-entries nil
                      ?f
                      ;; order entries by their quotes (the quote in the main
                      ;; library having higher priority)
                      #'(lambda () (save-excursion
                                     (org-end-of-meta-data)
                                     (forward-line)
                                     (let ((main-quote (thing-at-point 'line t))
                                           (other-quotes (bibli-paris/get-entry-quotes)))
                                       ;; (message "%s" result)
                                       (concat main-quote " " other-quotes)))))))


;; update entries

(defun bibli-paris/fetch-entry-holdings-by-id (recnum)
  "Return a deferred object that downloads JSON metadata about which library
have the entry specified by its record number RECNUM (string) available."
  (deferred:$
    (request-deferred bibli-paris/holdings-api-url
                      :type "POST"
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
                                  (json-read))))
    (deferred:nextc it
      (lambda (response)
        (let ((error-thrown (request-response-error-thrown response)))
          (if error-thrown
              (let ((error-symbol (car error-thrown))
                    (error-data (cdr error-thrown)))
                (signal error-symbol error-data))
            (let* ((data (request-response-data response))
                   (d (gethash "d" data)))
              (if d (gethash "Holdings" d) nil))))))))

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


(defun bibli-paris/clean-quote (quote)
  "Remove extra whitespace from and uniformizes the quote QUOTE."
  (let ((blank "[[:blank:]\r\n]+"))
    (string-trim (replace-regexp-in-string
                  "BD EN RESERVE" "EN RESERVE BD"
                  (replace-regexp-in-string blank " " quote t t)
                  t t)
                 blank blank)))

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
      (if new-quote (progn
                      (newline)
                      (insert new-quote)
                      (newline)))
      (setq begin (point))
      (org-next-visible-heading 1)
      (setq end (point))
      (delete-region begin end)
      (newline)
      (message "Set quote to \"%s\"" new-quote))))

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
    (message "Updating %s (%s) ..." (bibli-paris/get-entry-title) (bibli-paris/get-entry-author))
    (bibli-paris/update-entry-schedule-from holding)
    (bibli-paris/update-entry-quote-from holding)
    (bibli-paris/update-availability-at-central-library holdings)))

;;;###autoload
(defun bibli-paris/update-entry ()
  "Update the schedule and quote of the entry at point."
  (interactive
   (deferred:$
     (bibli-paris/fetch-entry-holdings-by-id (bibli-paris/get-entry-recnum))
     (deferred:nextc it 'bibli-paris/update-entry-from))))

(defun bibli-paris/async-update-entries-at-points (pom-recnum-seq)
  "Update all entries specified by their positions and record numbers in
POM-RECNUM-SEQ, fetching the corresponding data asynchronously."
  (let ((pom-holdingsd-seq
         (seq-map
          (lambda (pom-recnum)
            (let ((pom (car pom-recnum))
                  (recnum (cdr pom-recnum)))
              `(,pom . ,(deferred:$
                          (deferred:call 'message
                            "Fetching holdings for %s (%s) ..."
                            (bibli-paris/get-entry-title pom)
                            (bibli-paris/get-entry-author pom))
                          (bibli-paris/fetch-entry-holdings-by-id recnum)))))
          pom-recnum-seq)))
    (seq-reduce
     (lambda (prevd pom-holdingsd)
       (let ((pom (car pom-holdingsd))
             (holdingsd (cdr pom-holdingsd)))
         (deferred:$
           (deferred:parallel
             (deferred:$ prevd (deferred:nextc it `(lambda () ,pom)))
             holdingsd)
           (deferred:nextc it
             (lambda (pom-holdings)
               (let ((pom (car pom-holdings))
                     (holdings (car (cdr pom-holdings))))
                 (save-excursion
                   (goto-char pom)
                   (bibli-paris/update-entry-from holdings))))))))
     pom-holdingsd-seq
     (deferred:call 'message "Updating batch ..."))))

(defun bibli-paris/update-entries-sequential ()
  "Update all entries' schedules and quotes, fetching the corresponding data
sequentially. Terribly inefficient but works."
  (let ((poms (org-map-entries 'point)))
    (deferred:loop
      (seq-reverse poms)
      (lambda (pom) (deferred:$
                      (deferred:call 'goto-char pom)
                      (deferred:nextc it 'bibli-paris/update-entry))))))

(defun bibli-paris/update-entries-batch ()
  "Update all entries' schedules and quotes, by batches so as to prevent
emacs from opening too many files."
  (let ((poms (org-map-entries (lambda ()
                                 `(,(point) . ,(bibli-paris/get-entry-recnum))))))
    (deferred:$
      (deferred:next (lambda () (message "Update started.")))
      (deferred:loop
        (seq-partition (seq-reverse poms) bibli-paris/max-asynchronous-processes)
        'bibli-paris/async-update-entries-at-points)
      (deferred:nextc it 'bibli-paris/sort)
      (deferred:nextc it (lambda () (message "Update done."))))))

;;;###autoload
(defun bibli-paris/update-entries ()
  "Update all entries' schedules and quotes."
  (interactive)
  (bibli-paris/update-entries-batch))


;; import entries

(defun bibli-paris/insert-csv-entry (keys row &optional tags state old)
  "Insert at point a new entry described by a list of keys KEYS and associated
values in ROW, and set the tags TAGS (string seq) and the state STATE (string that
defaults to TODO.). If OLD is not nil, only update the properties and tags without
inserting the heading."
  (let ((title (bibli-paris/get-csv-title row))
        (recnum (bibli-paris/get-csv-recnum row)))
    (let ((heading (format "* %s [[%s][%s]]"
                           (if state state "TODO")
                           (concat bibli-paris/base-entry-url recnum)
                           title)))
      (if (not old)
          (progn (newline) (insert heading)))
      (cl-mapc (lambda (key value)
                 (let ((formatted-key (upcase
                                       (replace-regexp-in-string " " "_"
                                                                 key)))
                       (formatted-value (string-trim value)))
                   (if (not (string-equal formatted-value ""))
                       (org-set-property formatted-key formatted-value))))
               keys row)
      (org-toggle-tag tags 'on))))

(defun bibli-paris/insert-or-update-csv-entries (keys rows recnum-lines
                                                      &optional tags state)
  "Insert entries described by a list of keys KEYS and associated to values in
ROW at point. Also set the tags TAGS (string seq) and the state STATE (string
that defaults to TODO.). If an entry has a record number found in RECNUM-POMS
(string to marker hash table), only update the entry at corresponding point
(without inserting the heading)."
  ;; TODO : remove race conditions
  (seq-do (lambda (row)
            (let ((recnum (bibli-paris/get-csv-recnum row)))
              (if recnum
                  (let ((line (gethash recnum recnum-lines)))
                    (save-excursion
                      (if line
                          (progn
                            (goto-char (point-min))
                            (org-next-visible-heading line)
                            (message "Updating %s (%s) ..."
                                     (bibli-paris/get-entry-title)
                                     (bibli-paris/get-entry-author)))
                        (progn
                          (goto-char (point-max))
                          (message "Inserting %s (%s) ..."
                                   (bibli-paris/get-entry-title)
                                   (bibli-paris/get-entry-author))))
                      (bibli-paris/insert-csv-entry keys row tags state line))))))
          rows))

(defun bibli-paris/parse-csv (path-to-csv)
  "Load a CSV file from PATH-TO-CSV (string) into a list of rows, each row being
being encoded as a list of strings."
  (let ((csv-buffer (generate-new-buffer "bibli-paris/csv-to-import-from")))
    (let ((result
           (save-current-buffer
             (set-buffer csv-buffer)
             (insert-file-contents path-to-csv)
             (parse-csv-string-rows (buffer-string) ?\; ?\" "\n"))))
      (kill-buffer csv-buffer)
      result)))

;;;###autoload
(defun bibli-paris/import-from-csv (&optional path-to-csv tags state)
  "Import entries from the CSV file downloaded on
https://bibliotheques.paris.fr/ whose path is given by PATH-TO-CSV (string).
All the imported entries are set with the tag TAGS (string) and in the state
STATE (string)."
  (interactive (list (read-file-name "Import from : "
                                     nil
                                     nil
                                     nil
                                     bibli-paris/default-path-to-csv)
                     (read-string "Tags : ")
                     (read-string "State (default : TODO) : ")))
  (let ((recnum-lines (make-hash-table :test 'equal
                                       :size (bibli-paris/number-of-entries)
                                       :weakness 'key-and-value))
        (entry-number 0)
        (path-to-csv (if path-to-csv path-to-csv bibli-paris/default-path-to-csv)))
    (message "Importing library entries from %s ..." path-to-csv)
    (org-map-entries (lambda ()
                       (progn
                         (puthash (bibli-paris/get-entry-recnum) entry-number recnum-lines)
                         (setq entry-number (1+ entry-number)))))
    (let ((csv-rows (bibli-paris/parse-csv path-to-csv)))
      (bibli-paris/insert-or-update-csv-entries (car csv-rows)
                                                (cdr csv-rows)
                                                recnum-lines
                                                tags
                                                state))
    (message "Import done.")))


;; archive entries

;;;###autoload
(defun bibli-paris/archive-all-read ()
  "Archive all entries in the DONE state."
  (interactive)
  (org-map-entries (lambda ()
                     (if (equal (org-get-todo-state) "DONE")
                         (progn
                           ;; archiving an entry moves the cursor to next entry
                           ;; so we move it back to the previous entry
                           (org-archive-subtree)
                           (setq org-map-continue-from (outline-get-last-sibling))
                           )))))

;; minor mode

;;;###autoload
(define-minor-mode bibli-paris/mode
  "Manage reading lists of documents available in Paris' libraries."
  :lighter "bibli-paris")

(provide 'bibli-paris)
