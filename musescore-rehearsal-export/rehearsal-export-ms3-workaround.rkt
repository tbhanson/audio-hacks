#lang racket

;; Generates one rehearsal MP3 per voice from a MuseScore choir score,
;; working around a MuseScore 4.x regression where per-channel mixer
;; state (mute, solo, and apparently plain volume too) is not honored
;; during audio export -- exports come out sounding "tutti" regardless
;; of what's set in the Channel/controller data.
;;
;; Workaround (verified previously via pairwise_diff.sh on this same
;; score): round-trip through MuseScore 3.6.2, which still respects
;; per-channel volume during audio export.
;;
;; Pipeline:
;;   1. MS4 CLI exports the original score to MusicXML (format-neutral,
;;      strips MuseScore-4-specific mixer/channel state).
;;   2. MS3 CLI imports that MusicXML and re-saves as an MS3-format
;;      .mscx (plain XML we can edit).
;;   3. For each voice, this script edits that MS3 .mscx's Channel
;;      volume controllers, then calls MS3's CLI to export mp3.
;;
;; IMPORTANT: the MS3-format Channel/controller XML shape hasn't been
;; verified against a real file yet -- it's assumed to match the MS4
;; shape (same <controller ctrl="7" value="..."/> convention), since
;; that's the same legacy MIDI-CC7 mechanism MS3 originated. Run once,
;; then check the printed sample Channel block against what you expect
;; before trusting a full batch run.

(require xml racket/system racket/path)

;; ---------- CONFIGURATION ----------

;; Original score (mscz or mscx), untouched throughout
;(define SOURCE-SCORE "See_my_friends_SATB_MS4.mscz")
(define SOURCE-SCORE
  "/Users/tbh/Library/CloudStorage/Dropbox/music/MuseScore/ScoresMS4/TryArranging/See_my_friends_SATB_MS4.mscz"
)

;; Where all intermediate and final files go
(define OUTPUT-DIR "rehearsal-mp3s-ms3")

;; Voice names, must match <trackName> text in the score exactly
(define voices '("Soprano" "Alto" "Tenor" "Bass"))

;; MIDI CC7 volume values (0-127)
(define solo-volume "127")
(define quiet-volume "75")

;; CLI paths -- adjust to match your installs
(define MSCORE4-CLI "/Applications/MuseScore 4.app/Contents/MacOS/mscore")
(define MSCORE3-CLI "/Applications/MuseScore 3.app/Contents/MacOS/mscore") ; confirm this path

(define CLEANUP-TEMP-FILES? #t)

;; ---------- XML helpers (same as the MS4 version) ----------

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
    [(not (member name voices)) part]
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

;; Print the first Channel block found for a named voice, so you can
;; sanity-check the MS3 file's shape before trusting the full batch run.
(define (show-sample-channel tree voice-name)
  (let loop ([x tree])
    (cond
      [(not (pair? x)) #f]
      [(and (eq? (xexpr-tag x) 'Part) (equal? (part-trackname x) voice-name))
       (define inst (findf (lambda (k) (and (pair? k) (eq? (xexpr-tag k) 'Instrument)))
                            (xexpr-children x)))
       (define chan (and inst (findf main-channel? (xexpr-children inst))))
       (when chan
         (printf "Sample ~a Channel block from the MS3 file:\n~a\n\n" voice-name chan))]
      [(pair? x) (for-each loop (xexpr-children x))]
      [else (void)])))

;; ---------- Main ----------

(define (run-cli . args)
  (define ok? (apply system* args))
  (unless ok? (eprintf "  Warning: command failed: ~a\n" (string-join args " ")))
  ok?)

(define (main)
  (unless (file-exists? SOURCE-SCORE)
    (error 'rehearsal-export "SOURCE-SCORE not found: ~a" SOURCE-SCORE))
  (make-directory* OUTPUT-DIR)

  (define musicxml-path (build-path OUTPUT-DIR "intermediate.musicxml"))
  (define ms3-mscx-path (build-path OUTPUT-DIR "base-ms3.mscx"))

  (printf "Step 1: exporting MusicXML via MuseScore 4...\n")
  (run-cli MSCORE4-CLI "-o" (path->string musicxml-path) SOURCE-SCORE)

  (printf "Step 2: importing into MuseScore 3, saving as .mscx...\n")
  (run-cli MSCORE3-CLI "-o" (path->string ms3-mscx-path) (path->string musicxml-path))

  (unless (file-exists? ms3-mscx-path)
    (error 'rehearsal-export "MS3 import/conversion failed -- no ~a produced" ms3-mscx-path))

  (define base-tree (read-mscx ms3-mscx-path))

  ;; Sanity check: print one voice's Channel block before batch-exporting all four
  (show-sample-channel base-tree (car voices))

  (define base-name (path->string (path-replace-extension (file-name-from-path SOURCE-SCORE) "")))

  (for ([v voices])
    (define temp-mscx (build-path OUTPUT-DIR (format "~a.mscx" v)))
    (define out-mp3   (build-path OUTPUT-DIR (format "~a_~a.mp3" base-name v)))
    (printf "Generating ~a...\n" out-mp3)
    (write-mscx (transform-doc base-tree v) temp-mscx)
    (run-cli MSCORE3-CLI "-o" (path->string out-mp3) (path->string temp-mscx))
    (when CLEANUP-TEMP-FILES? (delete-file temp-mscx)))

  (printf "Done. Files in ~a/\n" OUTPUT-DIR)
  (printf "Run pairwise_diff.sh on that directory to confirm the voices genuinely differ.\n"))

(main)
