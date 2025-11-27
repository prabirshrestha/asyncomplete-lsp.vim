if exists('g:asyncomplete_lsp_loaded')
    finish
endif
let g:asyncomplete_lsp_loaded = 1

let s:servers = {} " { server_name: 1 }

augroup asyncomplete_lsp
    au!
    au User lsp_server_init call s:server_initialized()
    au User lsp_server_exit call s:server_exited()
augroup END

function! s:server_initialized() abort
    let l:server_names = lsp#get_server_names()
    for l:server_name in l:server_names
        if has_key(s:servers, l:server_name)
            continue
        endif
        let l:init_capabilities = lsp#get_server_capabilities(l:server_name)
        if !has_key(l:init_capabilities, 'completionProvider') && !has_key(l:init_capabilities, 'inlineCompletionProvider')
            continue
        endif

        let l:server = lsp#get_server_info(l:server_name)
        let l:name = s:generate_asyncomplete_name(l:server_name)
        let l:source_opt = {
            \ 'name': l:name,
            \ 'completor': function('s:completor', [l:server, bufnr('.'), has_key(l:init_capabilities, 'inlineCompletionProvider')]),
            \ }
        if has_key(l:init_capabilities, 'completionProvider') && type(l:init_capabilities['completionProvider']) == type({}) && has_key(l:init_capabilities['completionProvider'], 'triggerCharacters')
            let l:source_opt['triggers'] = { '*': l:init_capabilities['completionProvider']['triggerCharacters'] }
        elseif has_key(l:init_capabilities, 'inlineCompletionProvider') && type(l:init_capabilities['inlineCompletionProvider']) == type({}) && has_key(l:init_capabilities['inlineCompletionProvider'], 'triggerCharacters')
            let l:source_opt['triggers'] = { '*': l:init_capabilities['inlineCompletionProvider']['triggerCharacters'] }
        endif
        if has_key(l:server, 'allowlist')
            let l:source_opt['allowlist'] = l:server['allowlist']
        elseif has_key(l:server, 'whitelist')
            let l:source_opt['allowlist'] = l:server['whitelist']
        endif
        if has_key(l:server, 'blocklist')
            let l:source_opt['blocklist'] = l:server['blocklist']
        elseif has_key(l:server, 'blacklist')
            let l:source_opt['blocklist'] = l:server['blacklist']
        endif
        if has_key(l:server, 'priority')
            let l:source_opt['priority'] = l:server['priority']
        endif
        call asyncomplete#register_source(l:source_opt)
        let s:servers[l:server_name] = 1
    endfor
endfunction

function! s:server_exited() abort
    let l:server_names = lsp#get_server_names()
    for l:server_name in l:server_names
        if !has_key(s:servers, l:server_name)
            continue
        endif
        let l:name = s:generate_asyncomplete_name(l:server_name)
        if s:servers[l:server_name]
            call asyncomplete#unregister_source(l:name)
        endif
        unlet s:servers[l:server_name]
    endfor
endfunction

function! s:generate_asyncomplete_name(server_name) abort
    return 'asyncomplete_lsp_' . a:server_name
endfunction

function! s:completor(server, bufnr, inline, opt, ctx) abort
    let l:position = lsp#get_position()
    if a:inline
        call lsp#send_request(a:server['name'], {
            \ 'method': 'textDocument/inlineCompletion',
            \ 'params': {
            \   'textDocument': lsp#get_text_document_identifier(),
            \   'position': l:position,
            \   'context': { 'triggerKind': 2 },
            \ },
            \ 'on_notification': function('s:handle_inline_completion', [a:server, l:position, a:opt, a:ctx, a:bufnr]),
            \ })
    else
        call lsp#send_request(a:server['name'], {
            \ 'method': 'textDocument/completion',
            \ 'params': {
            \   'textDocument': lsp#get_text_document_identifier(),
            \   'position': l:position,
            \ },
            \ 'on_notification': function('s:handle_completion', [a:server, l:position, a:opt, a:ctx, a:bufnr]),
            \ })
    endif
endfunction

function! s:handle_completion(server, position, opt, ctx, bufnr, data) abort
    if lsp#client#is_error(a:data) || !has_key(a:data, 'response') || !has_key(a:data['response'], 'result')
        return
    endif

    let l:options = {
        \ 'server': a:server,
        \ 'position': a:position,
        \ 'response': a:data['response'],
        \ }

    let l:completion_result = lsp#omni#get_vim_completion_items(l:options)

    let l:col = a:ctx['col']
    let l:typed = a:ctx['typed']
    let l:kw = matchstr(l:typed, get(b:, 'asyncomplete_refresh_pattern', '\k\+$'))
    let l:kwlen = len(l:kw)
    let l:startcol = l:col - l:kwlen
    let l:startcol = min([l:startcol, get(l:completion_result, 'startcol', l:startcol)])

    call asyncomplete#complete(a:opt['name'], a:ctx, l:startcol, l:completion_result['items'], l:completion_result['incomplete'])
endfunction

function! s:handle_inline_completion(server, position, opt, ctx, bufnr, data) abort
    if lsp#client#is_error(a:data) || !has_key(a:data, 'response') || !has_key(a:data['response'], 'result')
        return
    endif
    let l:response = get(a:data, 'response', {})
    let l:items = get(get(l:response, 'result', {}), 'items', [])
    if empty(l:items)
        return
    endif
    let b:vim_lsp_inline_completion_info = [a:bufnr, l:items, a:position]
    let b:vim_lsp_inline_completion_index = 0
    let l:item = l:items[0]
    let l:text = get(l:item, 'insertText', '')
    call s:display_inline_completion(a:bufnr, l:text, a:position)

    augroup asyncomplete_lsp_inline_complete_clear
        au!
        au InsertLeave * ++once call s:clear_inline_all()
    augroup END

    if !hasmapto('<Plug>(asyncomplete_lsp_inline_complete_accept)', 'i')
        exe 'imap' get(g:, 'asyncomplete_lsp_inline_complete_accept_key', '<tab>') '<plug>(asyncomplete_lsp_inline_complete_accept)'
    endif
    if !hasmapto('<Plug>(asyncomplete_lsp_inline_complete_next)', 'i')
        exe 'imap' get(g:, 'asyncomplete_lsp_inline_complete_next_key', '<a-]>') '<plug>(asyncomplete_lsp_inline_complete_next)'
    endif
    if !hasmapto('<Plug>(asyncomplete_lsp_inline_complete_previous)', 'i')
        exe 'imap' get(g:, 'asyncomplete_lsp_inline_complete_previous_key', '<a-[>') '<plug>(asyncomplete_lsp_inline_complete_previous)'
    endif
endfunction

inoremap <expr> <silent> <Plug>(asyncomplete_lsp_inline_complete_accept) (pumvisible() ? "<C-e>" : "") .. "<c-r>=<SID>accept_inline_completion()<cr>"
inoremap <expr> <silent> <Plug>(asyncomplete_lsp_inline_complete_next) (pumvisible() ? "<C-e>" : "") .. "<c-r>=<SID>next_inline_completion()<cr>"
inoremap <expr> <silent> <Plug>(asyncomplete_lsp_inline_complete_previous) (pumvisible() ? "<C-e>" : "") .. "<c-r>=<SID>previous_inline_completion()<cr>"

function! s:accept_inline_completion() abort
    if !exists('b:vim_lsp_inline_completion_text') || empty(b:vim_lsp_inline_completion_text)
        let l:key = get(g:, 'asyncomplete_lsp_inline_complete_accept_key', '<tab>')
        return substitute(l:key, '<\([A-Za-z\-\]\[]\+\)>', '\=eval(''"\<'' .. submatch(1) .. ''>"'')', 'g')
    endif
    noautocmd silent! call setline('.', '')
    if b:vim_lsp_inline_completion_text =~# '\n'
        for l:line in split(b:vim_lsp_inline_completion_text, "\n", 1)
            noautocmd silent! call setline('.', l:line)
            noautocmd silent! put=''
        endfor
        call s:clear_inline_all()
        return ""
    endif
    call setline('.', b:vim_lsp_inline_completion_text)
    noautocmd silent! normal! $
    call s:clear_inline_all()
    return "\<right>"
endfunction

function! s:next_inline_completion() abort
    if !exists('b:vim_lsp_inline_completion_info') || !exists('b:vim_lsp_inline_completion_index')
         return ""
    endif
    let l:info = b:vim_lsp_inline_completion_info
    let b:vim_lsp_inline_completion_index = b:vim_lsp_inline_completion_index == len(l:info[1]) - 1 ? 0 : b:vim_lsp_inline_completion_index + 1
    let l:item = l:info[1][b:vim_lsp_inline_completion_index]
    let l:text = get(l:item, 'insertText', '')
    call s:display_inline_completion(l:info[0], l:text, l:info[2])
    return ""
endfunction

function! s:previous_inline_completion() abort
    if !exists('b:vim_lsp_inline_completion_info') || !exists('b:vim_lsp_inline_completion_index')
         return ""
    endif
    let l:info = b:vim_lsp_inline_completion_info
    let b:vim_lsp_inline_completion_index = b:vim_lsp_inline_completion_index == 0 ? len(l:info[1]) - 1 : b:vim_lsp_inline_completion_index - 1
    let l:item = l:info[1][b:vim_lsp_inline_completion_index]
    let l:text = get(l:item, 'insertText', '')
    call s:display_inline_completion(l:info[0], l:text, l:info[2])
    return ""
endfunction

function! s:clear_inline_preview() abort
    let l:prop_type = 'vim_lsp_inline_completion_virtual_text'
    if !empty(prop_type_get(l:prop_type))
        call prop_remove({'type': l:prop_type, 'all': v:true})
    endif
    if exists('b:vim_lsp_inline_completion_text')
        unlet b:vim_lsp_inline_completion_text
    endif
endfunction

function! s:clear_inline_all() abort
    call s:clear_inline_preview()
    if exists('b:vim_lsp_inline_completion_info')
        unlet b:vim_lsp_inline_completion_info
    endif
    if exists('b:vim_lsp_inline_completion_index')
        unlet b:vim_lsp_inline_completion_index
    endif
endfunction

function! s:display_inline_completion(bufnr, text, pos) abort
    let l:prop_type = 'vim_lsp_inline_completion_virtual_text'
    if empty(prop_type_get(l:prop_type))
        call prop_type_add(l:prop_type, { 'highlight': 'NonText' })
    endif
    call s:clear_inline_preview()

    let l:lines = split(a:text, "\r\n\\=\\|\n", 1)
    if empty(l:lines[-1])
        call remove(l:lines, -1)
    endif

    let l:curline = getline('.')
    let l:offset = col('.') - 1
    let l:delete = strchars(strpart(l:curline, l:offset, len(l:curline) - l:offset))

    let l:new_suffix = l:lines[0]
    let l:cur_suffix = getline('.')[col('.') - 1 :]
    let l:new_prefix = strpart(l:new_suffix, l:offset)
    let l:inset = ''
    while l:delete > 0 && !empty(l:new_suffix)
        let l:last_char = matchstr(l:new_suffix, '.$')
        let l:new_suffix = matchstr(l:new_suffix, '^.\{-\}\ze.$')
        if l:last_char ==# matchstr(l:cur_suffix, '.$')
            if !empty(l:inset)
                call prop_add(line('.'), col('.') + len(l:cur_suffix), {'type': l:prop_type, 'text': l:inset})
                let l:inset = ''
            endif
            let l:cur_suffix = matchstr(l:cur_suffix, '^.\{-\}\ze.$')
            let l:delete -= 1
        else
            let l:inset = l:last_char . l:inset
        endif
    endwhile
    let l:new_suffix = l:new_prefix
    if !empty(l:new_suffix . l:inset)
        call prop_add(line('.'), col('.'), {'type': l:prop_type, 'text': l:new_suffix . l:inset})
    endif
    for l:curline in l:lines[1:]
        call prop_add(line('.'), 0, {'type': l:prop_type, 'text_align': 'below', 'text': l:curline})
    endfor
    let b:vim_lsp_inline_completion_text = join(l:lines, "\n")
endfunction
