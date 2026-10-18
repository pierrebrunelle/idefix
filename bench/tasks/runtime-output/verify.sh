#!/bin/bash
cd "$1" && [ "$(python3 jsonq.py config.json name 2>/dev/null)" = "webserver" ] && [ "$(python3 jsonq.py config.json port 2>/dev/null)" = "8080" ]
