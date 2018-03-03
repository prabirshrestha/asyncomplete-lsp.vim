if exists('g:asyncomplete_lsp_loaded')
    finish
endif
let g:asyncomplete_lsp_loaded = 1

let s:servers = {} " { server_name: 1 }

au User lsp_server_init call s:server_initialized()
au User lsp_server_exit call s:server_exited()

function! s:server_initialized() abort
    let l:server_names = lsp#get_server_names()
    for l:server_name in l:server_names
        if !has_key(s:servers, l:server_name)
            let l:init_capabilities = lsp#get_server_capabilities(l:server_name)
            if has_key(l:init_capabilities, 'completionProvider')
                " TODO: support triggerCharacters
                let l:name = s:generate_asyncomplete_name(l:server_name)
                let l:source_opt = {
                    \ 'name': l:name,
                    \ 'completor': function('s:completor', [l:server_name]),
                    \ 'refresh_pattern': '\(\k\+$\|\.$\|:$\)',
                    \ }
                let l:server = lsp#get_server_info(l:server_name)
                if has_key(l:server, 'whitelist')
                    let l:source_opt['whitelist'] = l:server['whitelist']
                endif
                if has_key(l:server, 'blacklist')
                    let l:source_opt['blacklist'] = l:server['blacklist']
                endif
                call asyncomplete#register_source(l:source_opt)
                let s:servers[l:server_name] = 1
            else
                let s:servers[l:server_name] = 0
            endif
        endif
    endfor
endfunction

function! s:server_exited() abort
    let l:server_names = lsp#get_server_names()
    for l:server_name in l:server_names
        if has_key(s:servers, l:server_name)
            let l:name = s:generate_asyncomplete_name(l:server_name)
            if s:servers[l:server_name]
                call asyncomplete#unregister_source(l:name)
            endif
            unlet s:servers[l:server_name]
        endif
    endfor
endfunction

function! s:generate_asyncomplete_name(server_name) abort
    return 'asyncomplete_lsp_' . a:server_name
endfunction

function! s:completor(server_name, opt, ctx) abort
    call lsp#send_request(a:server_name, {
        \ 'method': 'textDocument/completion',
        \ 'params': {
        \   'textDocument': lsp#get_text_document_identifier(),
        \   'position': lsp#get_position(),
        \ },
        \ 'on_notification': function('s:handle_completion', [a:server_name, a:opt, a:ctx]),
        \ })
endfunction

function! s:handle_completion(server_name, opt, ctx, data) abort
    if lsp#client#is_error(a:data) || !has_key(a:data, 'response') || !has_key(a:data['response'], 'result')
        return
    endif

    let l:result = a:data['response']['result']

    if type(l:result) == type([])
        let l:items = l:result
        let l:incomplete = 0
    else
        let l:items = l:result['items']
        let l:incomplete = l:result['isIncomplete']
    endif

    call map(l:items, 's:format_completion_item(v:val)')

    let l:col = a:ctx['col']
    let l:typed = a:ctx['typed']
    let l:kw = matchstr(l:typed, '\w\+$')
    let l:kwlen = len(l:kw)
    let l:startcol = l:col - l:kwlen

    call asyncomplete#complete(a:opt['name'], a:ctx, l:startcol, l:items, l:incomplete)
endfunction

function! s:format_completion_item(item)
    if has_key(a:item, 'insertText') && !empty(a:item['insertText'])
        if has_key(a:item, 'insertTextFormat') && a:item['insertTextFormat'] != 1
            let l:word = a:item['label']
        else
            let l:word = a:item['insertText']
        endif
        let l:abbr = a:item['label']
    else
        let l:word = a:item['label']
        let l:abbr = ''
    endif
    let l:menu = lsp#omni#get_kind_text(a:item)
    return {'word': l:word, 'abbr': l:abbr, 'menu': l:menu, 'icase': 1, 'dup': 1}
endfunction
