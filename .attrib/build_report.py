#!/usr/bin/env python3
"""Inline report_data.json into report.html -> report.built.html (self-contained)."""
import json, sys, pathlib

OUT = pathlib.Path('/Users/rtomasi/cousas/duktape-c3/.attrib')
tpl = (OUT / 'report.html').read_text()
data = json.load(open(OUT / 'report_data.json'))

# </script> inside the JSON would end the block early
blob = json.dumps(data, separators=(',', ':')).replace('</', '<\\/')
# Standalone file: nothing supplies a charset, so a browser sniffs latin-1 and
# renders em dashes as "a€"". Emit a full document with an explicit meta charset.
body = tpl.replace('__DATA__', blob)
# split the leading <title>/<style> block into <head>, everything else into <body>
i = body.find('</style>')
head, rest = (body[:i + 8], body[i + 8:]) if i != -1 else ('', body)
html = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        + head + '\n</head>\n<body>\n' + rest + '\n</body>\n</html>\n')
(OUT / 'report.built.html').write_text(html, encoding='utf-8')

print('template :', len(tpl), 'bytes')
print('payload  :', len(blob), 'bytes')
print('built    :', len(html), 'bytes ->', OUT / 'report.built.html')
n = data.get('narrative', {})
print('narrative: bugs', len(n.get('bugs', [])), '| decisions', len(n.get('decisions', [])))
