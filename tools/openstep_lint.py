#!/usr/bin/env python3
"""Minimal OpenStep/NeXT plist parser to lint pbxproj files. Reports the exact
line/column of the first structural error."""
import sys, re

text = open(sys.argv[1]).read()
i = 0
n = len(text)
line = 1

def err(msg):
    print(f"PARSE ERROR line {line}: {msg}")
    ctx = text[max(0,i-80):i+80].replace("\n", "\\n")
    print("context:", ctx)
    sys.exit(1)

def advance(k=1):
    global i, line
    for _ in range(k):
        if i < n and text[i] == "\n":
            line += 1
        i += 1

def skip_ws():
    global i
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            advance()
        elif text.startswith("/*", i):
            end = text.find("*/", i+2)
            if end < 0: err("unterminated block comment")
            while i < end+2: advance()
        elif text.startswith("//", i):
            while i < n and text[i] != "\n": advance()
        else:
            return

UNQUOTED = re.compile(r'[A-Za-z0-9_$./:-]')

def parse_string():
    global i
    if text[i] == '"':
        advance()
        while i < n:
            if text[i] == "\\":
                advance(2)
            elif text[i] == '"':
                advance()
                return True
            else:
                advance()
        err("unterminated quoted string")
    else:
        if not UNQUOTED.match(text[i]):
            err(f"unexpected character {text[i]!r} where value expected")
        while i < n and UNQUOTED.match(text[i]):
            advance()
        return True

def parse_value():
    skip_ws()
    if i >= n: err("unexpected EOF (value)")
    c = text[i]
    if c == "{":
        parse_dict()
    elif c == "(":
        parse_array()
    else:
        parse_string()

def parse_dict():
    global i
    assert text[i] == "{"
    advance()
    while True:
        skip_ws()
        if i >= n: err("unexpected EOF (dict)")
        if text[i] == "}":
            advance()
            return
        parse_string()          # key
        skip_ws()
        if i >= n or text[i] != "=":
            err("expected '=' after key")
        advance()
        parse_value()
        skip_ws()
        if i < n and text[i] == ";":
            advance()
        else:
            err("expected ';' after value")

def parse_array():
    global i
    assert text[i] == "("
    advance()
    while True:
        skip_ws()
        if i >= n: err("unexpected EOF (array)")
        if text[i] == ")":
            advance()
            return
        parse_value()
        skip_ws()
        if i < n and text[i] == ",":
            advance()
        elif i < n and text[i] == ")":
            advance()
            return
        else:
            err("expected ',' or ')' in array")

skip_ws()
parse_value()
skip_ws()
if i < n:
    err("trailing content after root object")
print("PLIST OK")
