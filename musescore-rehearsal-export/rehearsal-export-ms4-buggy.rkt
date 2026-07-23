#lang racket

;; Generates one rehearsal MP3 per voice from a MuseScore 4 choir score.
;; For each voice in `voices`, produces an mp3 where that voice is loud
;; and the others are quiet, using the standard MIDI CC7 volume controller.
;;
;; Usage:
;;   1. Set the CONFIGURATION values below.
;;   2. Make sure MSCX-PATH points at an *uncompressed* .mscx (unzip your .mscz first,
;;      or point at a scratch copy — never your original working file).
;;   3. Run:  racket rehearsal-export.rkt

(require xml racket/system racket/path)

;; ---------- CONFIGURATION ----------

;; Uncompressed .mscx to read (unzip the .mscz first: `unzip piece.mscz -d extracted`)
(define MSCX-PATH "extracted/See_my_friends_SATB_MS4.mscx")

;; Where to put the finished mp3s
(define OUTPUT-DIR "rehearsal-mp3s")

;; Voice names, must match <trackName> text in the score exactly
(define voices '("Soprano" "Alto" "Tenor" "Bass"))

;; MIDI CC7 volume values (0-127)
(define solo-volume "127")
(define quiet-volume "30")

;; Path to the MuseScore 4 CLI executable
(define MSCORE-CLI "/Applications/MuseScore 4.app/Contents/MacOS/mscore")

;; Delete the intermediate per-voice .mscx files after export?
(define CLEANUP-TEMP-FILES? #t)

;; ---------- XML helpers ----------

(define (xexpr-tag x) (and (pair? x) (symbol? (car x)) (car x)))

(define (has-attr-list? x)
  (and (pair? x) (pair? (cdr x)) (list? (cadr x))
       (andmap (lambda (a) (and (pair? a) (symbol? (car a)))) (cadr x))))

(define (xexpr-attrs x) (if (has-attr-list? x) (cadr x) '()))
(define (xexpr-children x) (if (has-attr-list? x) (cddr x) (cdr x)))
(define (rebuild-element x new-children) (list* (xexpr-tag x) (xexpr-attrs x) new-children))

(define (element-text x)
  (apply string-append (filter string? (xexpr-children x))))

;; ---------- Core transform ----------

;; Remove any existing ctrl="7" controller from a Channel's children and insert a fresh one.
(define (set-channel-volume channel-elem value)
  (define kids (xexpr-children channel-elem))
  (define without-old-volume
    (filter (lambda (k)
              (not (and (pair? k) (eq? (xexpr-tag k) 'controller)
                        (assoc 'ctrl (xexpr-attrs k))
                        (equal? (cadr (assoc 'ctrl (xexpr-attrs k))) "7"))))
            kids))
  (rebuild-element channel-elem
                    (cons `(controller ((ctrl "7") (value ,value))) without-old-volume)))

;; The main singing Channel has no "name" attribute (articulation channels like
;; pizzicato/arco do, and we leave those alone).
(define (main-channel? x)
  (and (pair? x) (eq? (xexpr-tag x) 'Channel) (not (assoc 'name (xexpr-attrs x)))))

(define (transform-instrument instrument value)
  (rebuild-element instrument
                    (map (lambda (k) (if (main-channel? k) (set-channel-volume k value) k))
                         (xexpr-children instrument))))

(define (part-trackname part)
  (define tn (findf (lambda (k) (and (pair? k) (eq? (xexpr-tag k) 'trackName)))
                     (xexpr-children part)))
  (and tn (element-text tn)))

(define (transform-part part target-voice)
  (define name (part-trackname part))
  (cond
    [(not (member name voices)) part] ; not a vocal part (e.g. accompaniment) -> leave alone
    [else
     (define value (if (equal? name target-voice) solo-volume quiet-volume))
     (rebuild-element part
                       (map (lambda (k)
                              (if (and (pair? k) (eq? (xexpr-tag k) 'Instrument))
                                  (transform-instrument k value)
                                  k))
                            (xexpr-children part)))]))

(define (transform-doc xexpr target-voice)
  (let loop ([x xexpr])
    (cond
      [(not (pair? x)) x]
      [(eq? (xexpr-tag x) 'Part) (transform-part x target-voice)]
      [else (rebuild-element x (map loop (xexpr-children x)))])))

;; ---------- I/O ----------

(define (read-mscx path)
  (xml->xexpr (document-element (with-input-from-file path read-xml))))

(define (write-mscx xexpr path)
  (with-output-to-file path #:exists 'replace
    (lambda ()
      (display "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
      (write-xml/content (xexpr->xml xexpr)))))

;; ---------- Main ----------

(define (main)
  (unless (file-exists? MSCX-PATH)
    (error 'rehearsal-export "MSCX-PATH not found: ~a" MSCX-PATH))
  (make-directory* OUTPUT-DIR)
  (define base-tree (read-mscx MSCX-PATH))
  (define base-name (path->string (path-replace-extension (file-name-from-path MSCX-PATH) "")))

  (for ([v voices])
    (define temp-mscx (build-path OUTPUT-DIR (format "~a.mscx" v)))
    (define out-mp3   (build-path OUTPUT-DIR (format "~a_~a.mp3" base-name v)))
    (printf "Generating ~a...\n" out-mp3)
    (write-mscx (transform-doc base-tree v) temp-mscx)
    (define ok? (system* MSCORE-CLI "-o" (path->string out-mp3) (path->string temp-mscx)))
    (unless ok? (eprintf "  Warning: MuseScore export may have failed for ~a\n" v))
    (when CLEANUP-TEMP-FILES? (delete-file temp-mscx)))

  (printf "Done. Files in ~a/\n" OUTPUT-DIR))

(main)
