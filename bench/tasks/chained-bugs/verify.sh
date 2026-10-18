#!/bin/bash
cd "$1" && python3 test_calc.py >/dev/null 2>&1 \
  && grep -qE "x \* x|x\*\*2|x \*\* 2" calc.py \
  && grep -qE "square\(a\) ?\+ ?square\(b\)|a\*a ?\+ ?b\*b|a \* a ?\+ ?b \* b|a\*\*2 ?\+ ?b\*\*2|a \*\* 2 ?\+ ?b \*\* 2" calc.py
