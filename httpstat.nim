import tables, json
import random, future
import terminal, times
import os, ospaths, osproc, posix
import strutils, pegs, unicode
import sequtils

randomize()

const VERSION = "0.1.0"
const
  HTTPS_TEMPLATE = """
    DNS Lookup   TCP Connection   TLS Handshake   Server Processing   Content Transfer
  [  $1   |    $2     |    $3    |      $4      |     $5     ]
               |                |               |                   |                 |
     namelookup:$6         |               |                   |                 |
                         connect:$7        |                   |                 |
                                     pretransfer:$8            |                 |
                                                       starttransfer:$9          |
                                                                                 total:$10
  """
  HTTP_TEMPLATE = """
    DNS Lookup   TCP Connection   Server Processing   Content Transfer
  [  $1   |   $2      |     $4       |     $5      ]
               |                |                   |                  |
     namelookup:$6         |                   |                  |
                         connect:$7            |                  |
                                       starttransfer:$9           |
                                                                  total:$10
  """

const curl_format = """'{
  "time_namelookup": %{time_namelookup},
  "time_connect": %{time_connect},
  "time_appconnect": %{time_appconnect},
  "time_pretransfer": %{time_pretransfer},
  "time_redirect": %{time_redirect},
  "time_starttransfer": %{time_starttransfer},
  "time_total": %{time_total},
  "speed_download": %{speed_download},
  "speed_upload": %{speed_upload},
  "remote_ip": "%{remote_ip}",
  "remote_port": "%{remote_port}",
  "local_ip": "%{local_ip}",
  "local_port": "%{local_port}"
}'"""


proc echo_help(): int {. discardable .} =
  var help: string = """
  Usage: httpstat URL [CURL_OPTIONS]
         httpstat -h | --help
         httpstat --version
  Arguments:
    URL     url to request, could be with or without `http(s)://` prefix
  Options:
    CURL_OPTIONS  any curl supported options, except for -w -D -o -S -s,
                  which are already used internally.
    -h --help     show this screen.
    -v --version     show version.
  Environments:
    HTTPSTAT_SHOW_BODY    Set to `true` to show response body in the output,
                          note that body length is limited to 1023 bytes, will be
                          truncated if exceeds. Default is `false`.
    HTTPSTAT_SHOW_IP      By default httpstat shows remote and local IP/port address.
                          Set to `false` to disable this feature. Default is `true`.
    HTTPSTAT_SHOW_SPEED   Set to `true` to show download and upload speed.
                          Default is `false`.
    HTTPSTAT_SAVE_BODY    By default httpstat stores body in a tmp file,
                          set to `false` to disable this feature. Default is `true`
    HTTPSTAT_CURL_BIN     Indicate the curl bin path to use. Default is `curl`
                          from current shell $PATH.
  """
  echo help

proc random_str(size: int): string =
  let words = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = ""  # return result
  for i in countup(0, size):
    result &= words[random(61)]  # len(words) == 62

proc format_str(s: string, size: int, mode: char): string =
  # py: {:^7}.format("hoge")
  # py: {:<7}.format("hoge")
  # py: {:>7}.format("hoge")
  let length = size - len(s)
  if mode == '^':
    let 
      left = length div 2
      right = length - left
    result = repeat(' ', left) & s & repeat(' ', right)
  elif mode == '<':
    result = s & repeat(' ', length)
  elif mode == '>':
    result = repeat(' ', length) & s

proc make_color(code: string): proc =
  proc color_func(s: string): string =
    if not isatty(stdout):  # https://nim-lang.org/docs/terminal.html
      return s
    var tpl: string = "\x1b[$1m$2\x1b[0m"

    return tpl % [code, s]
  return color_func

proc grayscale(i: int, s: string): string =
  var code: int = 232 + i
  return  make_color("38;5;" & $code)(s)

let
  red = make_color("31")
  green = make_color("32")
  yellow = make_color("33")
  blue = make_color("34")
  magenta = make_color("35")
  cyan = make_color("36")

  bold = make_color("1")
  underline = make_color("4")


proc main(): int =
  if paramCount() == 0:
    echo_help()
    quit(0)

  var argv: seq[string] = commandLineParams()

  let url = argv[0]
  if url in ["-h", "--help"]:
    echo_help()
    quit(0)
  elif url in ["-v", "--version"]:
    echo "httpstat $1" % [VERSION]
    quit(0)

  let
    show_body = if getEnv("HTTPSTAT_SHOW_BODY") == "": "false" else: getEnv("HTTPSTAT_SHOW_BODY")
    show_ip = if getEnv("HTTPSTAT_SHOW_IP") == "": "true" else: getEnv("HTTPSTAT_SHOW_IP")
    show_speed = if getEnv("HTTPSTAT_SHOW_SPEED") == "": "false" else: getEnv("HTTPSTAT_SHOW_SPEED")
    save_body = if getEnv("HTTPSTAT_SAVE_BODY") == "": "true" else: getEnv("HTTPSTAT_SAVE_BODY")
    curl_bin = if getEnv("HTTPSTAT_CURL_BIN") == "": "curl" else: getEnv("HTTPSTAT_CURL_BIN")

  # https://nim-lang.org/docs/future.html
  # py: [argv[i] for i in range(1, paramCount())]
  let curl_args = lc[argv[x] | (x <- 1..(paramCount() - 1)), string].join(" ")

  # check curl args
  var exclude_options = @[
    "-w", "--write-out",
    "-D", "--dump-header",
    "-o", "--output",
    "-s", "--silent"
  ]
  for i in exclude_options:
    if i in curl_args:
      echo yellow("Error: $1 is not allowed in extra curl args" % [i])
      quit(1)

  let
    bodyf = "/tmp/httpstatbody-" & getDateStr() & random_str(8) & getClockStr()
    headerf = "/tmp/httpstatheader-" & getDateStr() & random_str(8) &  getClockStr()

  # https://www.tutorialspoint.com/c_standard_library/c_function_setlocale.htm
  # https://nim-lang.org/docs/posix.html
  discard setlocale(LC_ALL, "C")
  let 
    cmd_core = @[curl_bin, "-w", curl_format, "-D", headerf, "-o", bodyf, "-s", "-S"]
    cmd = concat(cmd_core, @[curl_args, url])

  let p = execCmdEx(cmd.join(" "))  # tuple[output, exitCode]
  
  # print stderr
  if p.exitCode != 0:
    var msg = cmd
    msg[2] = "<output-format>"
    msg[4] = "<tempfile>"
    msg[6] = "<tempfile>"
    echo "> $1" % [msg.join(" ")]
    echo yellow("curl error: $1" % [p.output.split("\n")[0]])
    quit(p.exitCode)

  # parse output(json)
  let p_json: JsonNode = parseJson(p.output)
  
  var d = initTable[string, string]()
  for key, value in p_json:
    if startsWith(key, "time_"):
      d[key] = $int(p_json[key].getFNum() * 1000)
    else:
      d[key] = $value

  # calculate ranges
  d["range_dns"] = $d["time_namelookup"].parseInt()
  d["range_connection"] = $(d["time_connect"].parseInt() - d["time_namelookup"].parseInt())
  d["range_ssl"] = $(d["time_pretransfer"].parseInt() - d["time_connect"].parseInt())
  d["range_server"] = $(d["time_starttransfer"].parseInt() - d["time_pretransfer"].parseInt())
  d["range_transfer"] = $(d["time_total"].parseInt() - d["time_starttransfer"].parseInt())

  # ip
  if show_ip == "true":
    let s = "Connected to $1:$2 from $3:$4" % [
      cyan(d["remote_ip"]), cyan(d["remote_port"]),
      cyan(d["local_ip"]), cyan(d["local_port"]),
    ]
    echo s, "\n"

  # print header & body summary
  block header_block:
    let f: File = open(headerf, FileMode.fmRead)
    defer:
      f.close()
      removeFile(headerf)  # remove header tmp file

    var loop: int = 0
    while f.endOfFile == false:
      if loop == 0:
        let header = f.readLine().split("/")
        echo green(header[0]) & grayscale(14, "/") & cyan(header[1])
        inc(loop)
      else:
        let 
          header = f.readLine()
          pos = header.find(":")
        echo grayscale(14, header[0..pos]) & cyan(header[(pos + 1)..len(header)])

  block body_block:
    if show_body != "true":
      if save_body == "true":
        echo "$1 stored in: $2" % [green("Body"), bodyf]
      break body_block

    const body_limit = 1024
    let f: File = open(bodyf, FileMode.fmRead)
    defer:
      f.close()
      if save_body != "true":
        removeFile(bodyf)  # remove body tmp file
    
    let
      body = f.readAll()
      body_len = len(body)
    if body_len > body_limit:
      echo body[0..(body_limit - 1)] & cyan("..."), "\n"
      var s = "$1 is truncated ($2 out of $3)" % [green("Body"), $body_limit, $body_len]
      if save_body == "true":
        s.add(", stored in: {}" % [bodyf])
      echo s
    else:
      echo body

    echo HTTP_TEMPLATE.split("\n")

  # colorize template
  var tmp = (if url.startsWith("https://"): HTTPS_TEMPLATE else: HTTP_TEMPLATE)
  tmp = tmp[1..len(tmp)-1]

  var tpl_parts: seq[string] = tmp.split("\n")
  tpl_parts[0] = grayscale(16, tpl_parts[0])
  var templ: string = tpl_parts.join("\n")
  
  proc fmta(s: string): string =
    return cyan(format_str(s & "ms", 7, '^'))

  proc fmtb(s: string): string =
    return cyan(format_str(s & "ms", 7, '<'))

  let stat = templ % [
    fmta(d["range_dns"]), fmta(d["range_connection"]),
    fmta(d["range_ssl"]), fmta(d["range_server"]),
    fmta(d["range_transfer"]),

    fmtb(d["time_namelookup"]), fmtb(d["time_connect"]),
    fmtb(d["time_pretransfer"]), fmtb(d["time_starttransfer"]),
    fmtb(d["time_total"])
  ]

  echo "\n", stat


if isMainModule:
  discard main()
