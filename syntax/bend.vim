if exists("b:current_syntax")
  finish
endif

syn keyword bendKeyword def law type import as public private
syn keyword bendKeyword match case return do for exs where is let
syn keyword bendBuiltin IO Nat U32 U64 F32 F64 Bool String Char
syn keyword bendBoolean True False
syn match bendNumber "\<\d\+\%([._]\d\+\)*\%(n\|u\|i\|f\)\?\>"
syn match bendOperator "[+*/%=<>!&|~^?-]\|<\&>\|\.\^[.]\|\.\|\.\|\.\&\."
syn match bendConstructor "\<[A-Z][A-Za-z0-9_]*\>"
syn match bendAttribute "@\%(unsafe\|inline\|noinline\)\>"
syn region bendString start=+"+ skip=+\\.+ end=+"+ contains=bendEscape
syn region bendString start=+'+ skip=+\\.+ end=+'+ contains=bendEscape
syn match bendEscape "\\." contained
syn match bendComment "#.*$" contains=bendTodo
syn keyword bendTodo TODO FIXME XXX NOTE contained

hi def link bendKeyword Keyword
hi def link bendBuiltin Type
hi def link bendBoolean Boolean
hi def link bendNumber Number
hi def link bendOperator Operator
hi def link bendConstructor Constant
hi def link bendAttribute PreProc
hi def link bendString String
hi def link bendEscape SpecialChar
hi def link bendComment Comment
hi def link bendTodo Todo

let b:current_syntax = "bend"
