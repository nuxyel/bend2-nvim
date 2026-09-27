setlocal expandtab
setlocal shiftwidth=2
setlocal softtabstop=2
setlocal indentexpr=GetBendIndent()
setlocal indentkeys=o,O,0=case,0=def,0=law,0=type

function! GetBendIndent() abort
  let lnum = v:lnum - 1
  while lnum > 0 && getline(lnum) =~# '^\s*$'
    let lnum -= 1
  endwhile
  if lnum <= 0
    return 0
  endif
  let previous = getline(lnum)
  let current = getline(v:lnum)
  let indent = indent(lnum)
  if previous =~# ':\s*$' || previous =~# '\<\%(where\|do\|match\)\s*$'
    let indent += shiftwidth()
  endif
  if current =~# '^\s*\%(case\|def\|law\|type\)\>'
    let indent = max([0, indent - shiftwidth()])
  endif
  return indent
endfunction
