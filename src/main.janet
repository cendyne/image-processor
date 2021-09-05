(import sh)
(import json)
(import codec)

(defn random-name []
  (var name (as-> (os/cryptorand 12) ?
    (string ?)
    (codec/encode ?)
    (string/replace-all "=" "" ?)
    (string/replace-all "+" "-" ?)
    (string/replace-all "/" "_" ?)
    ))
  (when (or (string/has-prefix? "-" name) (string/has-prefix? "_" name))
    (set name (string "A" (string/slice name 1))))

  (when (or (string/has-suffix? "-" name) (string/has-suffix? "_" name))
    (set name (string (string/slice name 0 -2) "A")))
  name)


(def content-type-extensions {
  "image/jpeg" ".jpg"
  "image/jpg" ".jpg"
  "image/png" ".png"
  "image/avif" ".avif"
  "image/jxl" ".jxl"
  "image/gif" ".gif"
  "image/webp" ".webp"
  "video/webm" ".webm"
  "video/mp4" ".mp4"
  "video/quicktime" ".mov"
  "image/tiff" ".tiff"
  "application/json" ".json"
})

(defn gen-temp-file [content-type]
  (def extension (get content-type-extensions content-type))
  (unless extension (errorf "Content type %p not supported" content-type))
  (def temp (string "/tmp/" (random-name) extension))
  temp)

(defn png-file [contexts]
  (var png (get contexts :png-file))
  (if png png (do
    (set png (gen-temp-file "image/png"))
    (array/push (get contexts :temp-files) png-file)
    # TODO this depends on source content type like avif
    (sh/$ convert ,(get contexts :source-file) png-file)
    png
    )))

(defn to-imagemagick [contexts source source-type]
  (case source-type
    "image/avif"
    (do
       (def converted (gen-temp-file "image/png"))
       (array/push (get contexts :temp-files) converted)
       (sh/$ avifdec ,source ,converted)
       converted
      )
    "image/webp"
    (do
       (def converted (gen-temp-file "image/png"))
       (array/push (get contexts :temp-files) converted)
       (sh/$ dwebp ,source -o ,converted)
       converted
      )
    "image/jxl"
    (do
       (def converted (gen-temp-file "image/png"))
       (array/push (get contexts :temp-files) converted)
       (sh/$ djxl ,source ,converted)
       converted)
    # Fallback is supported by ImageMagick
    source))

(defn to-other [contexts source dest dest-type]
  (case dest-type
    "image/avif"
    (sh/$ avifenc ,source ,dest)
    "image/webp"
    (sh/$ cwebp ,source -o ,dest)
    "image/jxl"
    (sh/$ cjxl ,source ,dest)
    # Fallback to ImageMagick
    (sh/$ convert ,source ,dest)
    ))

(defn imagemagick-supported? [content-type]
  (case content-type
    "image/png" true
    "image/jpg" true
    "image/jpeg" true
    "image/gif" true
    "image/tiff" true
    false
  ))


(defn convert-image [contexts source source-type dest dest-type]
  (printf "Converting %p -> %p" source dest)
  (def source-image-magick (imagemagick-supported? source-type))
  (def dest-image-magick (imagemagick-supported? dest-type))

  (cond
    (= source-type dest-type)
    (sh/$ cp ,source ,dest)

    (and source-image-magick dest-image-magick)
    (sh/$ convert ,source ,dest)

    (and (not source-image-magick) dest-image-magick)
    (do
      (def source (to-imagemagick contexts source source-type))
      (sh/$ convert ,source ,dest)
      )

    (and source-image-magick (= "image/png" source-type) (not dest-image-magick))
    (do
      (to-other contexts source dest dest-type)
      )

    (and source-image-magick (not dest-image-magick))
    (do
      # Convert from whatever to png
      (def intermediate (to-imagemagick contexts source source-type))
      # Then to the destination format
      (to-other contexts intermediate dest dest-type)
      )

    true
    (to-other contexts source dest dest-type)
  ))

(defn resize-image [mode contexts source source-type dest dimensions]
  (printf "resizing %p to %p -> %p" source dimensions dest)
  (var mode mode)
  (case mode
    "scale" nil
    "scale-down" nil
    "thumbnail" nil
    (set mode "scale")
    )
  (var source (to-imagemagick contexts source source-type))
  (case mode
    "scale" (sh/$ convert ,source
      -resize ,dimensions
      ,dest
      )
    "scale-down" (sh/$ convert ,source
      -resize ,(string dimensions ">")
      ,dest
      )
    "thumbnail" (sh/$ convert ,source
      -resize ,(string dimensions "^")
      -gravity center
      -extent ,dimensions
      ,dest
      )
    (errorf "This should be unreachable, but the mode %p is unsupported" mode)
    )
  dest)

(defn action [baseUrl authorization contexts data]
  (var id (get data "id"))
  (unless id (error "id not specified"))
  (var output-content-type (get data "output"))
  (unless output-content-type (error "output not specified"))
  (var source (get contexts :source-file))
  (var source-type (get contexts :source-content-type))

  # Resize
  (var dimensions (get data "resize"))
  (var resize-mode (or (get data "resize-mode") (get data "resizeMode") "scale"))
  (when dimensions
    (def resize-png (gen-temp-file "image/png"))
    (array/push (get contexts :temp-files) resize-png)
    (resize-image resize-mode contexts source source-type resize-png dimensions)
    (set source resize-png)
    (set source-type "image/png")
    )

  # Convert
  (def converted (gen-temp-file output-content-type))
  (array/push (get contexts :temp-files) converted)
  (convert-image contexts source source-type converted output-content-type)
  (def output @{
    :queue (or (get data "output-queue") (get data "outputQueue"))
    :content-type output-content-type
    :final converted
    :data data
  })
  (put-in contexts [:outputs id] output)
)

(defn process [baseUrl authorization job-id]
  (try
    (do
      (def job-url (string baseUrl "/job/" job-id))
      (def job (sh/$< curl -s --header ,authorization ,job-url))
      (def data (json/decode job))
      (def extension (get content-type-extensions (get data "content-type")))
      (unless extension
        (errorf "Unexpected content type %p" (get data "content-type")))
      (def temp (string "/tmp/" (random-name) extension))
      (printf "Came up with file %p" temp)
      (def tempfile (file/open temp :w))
      (def contexts @{
        :source-content-type (get data "content-type")
        :source-file temp
        :temp-files @[temp]
        :png-file nil
        :outputs @{}
      })
      (var error nil)
      (try
        (do
          (file/write tempfile (codec/decode (get data "image")))
          (printf "File written %p" temp)
        )
        ([err fib]
          (set error true)
          (eprintf "Error while processing job %p" job-id)
          (debug/stacktrace fib err)
          )
      )
      (file/close tempfile)
      (unless error
        (each action-data (get data "actions" [])
          (try
            (action baseUrl authorization contexts action-data)
            ([err fib]
              (set error true)
              (eprintf "Action %p failed" action-data)
              (debug/stacktrace fib err)
              ))
          ))
      (unless error
        (each [id output] (pairs (get contexts :outputs))
          (def dest-queue (string baseUrl "/queues/" (get output :queue) "/job"))
          (printf "Uploading %p to %p" (get output :final) dest-queue)
          (def output-value (string (json/encode @{
            :content (sh/$< cat ,(get output :final) | base64)
            :content-type (get output :content-type)
            :id id
            :data (get output :data)
          })))
          (def post-body (gen-temp-file "application/json"))
          (array/push (get contexts :temp-files) post-body)
          (def f (file/open post-body :w))
          (try
            (file/write f output-value)
            ([err fib]
              (set error true)
              (file/close f)
              (error err)
              ))
          (file/close f)
          (try
            (sh/$< curl -X PUT -s
              --header ,authorization
              --header "Content-Type: application/json"
              --data ,(string "@" post-body)
              ,dest-queue)
            ([err fib]
              (set error true)
              (eprintf "Could not upload finished image")
              (debug/stacktrace fib err)
              )
            )))
      (each temp-file (get contexts :temp-files)
        (try
          (when (os/stat temp-file) (os/rm temp-file))
          ([err fib] (eprintf "Could not delete temp file %p" temp-file))))
      (unless error
        (printf "Deleting Job %p" job-id)
        (sh/$< curl -X DELETE -s --header ,authorization ,job-url)
        )
      (when error
        (printf "The job failed %p" job-id))
      )
    ([err fib]
      (eprintf "Error while processing job %p" job-id)
      (debug/stacktrace fib err)
    )))

(defn worker [baseUrl token queue]
  (def authorization (string "Authorization: Bearer replace-me"))
  (def queue-url (string baseUrl "/queues/" queue "/job"))
  (forever
    (var results false)
    (try
      (do
        (def jobs (sh/$< curl -s --header ,authorization ,queue-url))
        # (printf "Jobs %p" jobs)
        (def jobs (json/decode jobs))
        (each job (get jobs "jobs" [])
          (process baseUrl authorization job))
        )
      ([err fib]
        (eprintf "Error %p" err)
        (ev/sleep 60)
      ))
    (unless results
      (ev/sleep 1))
  ))

(defn main [& args]
  (let [baseUrl (get args 1 (get (os/environ) "BASE_URL" ""))
        token (get args 2 (get (os/environ) "TOKEN" ""))
        queue (get args 3 (get (os/environ) "QUEUE" "main"))
        ]
    (when (or (nil? baseUrl) (empty? baseUrl)) (error "BASE_URL not set"))
    (when (or (nil? token) (empty? token)) (error "TOKEN not set"))
    (when (or (nil? queue) (empty? queue)) (error "QUEUE not set"))
    (ev/call worker baseUrl token queue)
    ))

