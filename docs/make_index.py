#coding: utf-8

import os, sys, re
import glob, hashlib

def calc_sha1(path):
  s = hashlib.sha1()
  fd = open(path, "rb")
  while 1:
    b = fd.read(2048)
    if b == "":
      break
    s.update(b)

  return s.hexdigest()

def print_dir(dir):
  files = glob.glob(dir)
  print "<h4>%s</h4>" % os.path.dirname(dir)
  print "<table>"
  for file in sorted(files):
    href = file.replace(os.sep,"/")
    name = os.path.basename(file)
    size = os.path.getsize(file)
    sha1 = calc_sha1(file)

    print " <tr><td><a href=%s>%s</a><td align=right>%d<td>%s" % (href, name, size, sha1)
  print "</table>"


def main():
  print """
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf8">
<style type="text/css">

table, td, th {
  border: 0;
}

td, th {
  padding: 10px 10px;
}

</style>
<body>

<h2>らじるこプラグイン ファイル置き場</h2><br><br>

"""

  print_dir("release/v5/*.zip")
  print "\n<br><br>\n"
  print_dir("release/src/*")



main()



