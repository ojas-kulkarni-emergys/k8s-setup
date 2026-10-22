"""Read-only source-driven Bash walkthrough. Never invokes a shell or subprocess.

This is a deliberately bounded static interpreter, not a Bash implementation.
Unknown runtime values/conditions become form questions; unsupported syntax stops
the walkthrough instead of inventing commands or silently skipping work.
"""
import fnmatch
import re
import shlex
from pathlib import Path
import yaml
from fastapi import HTTPException


class NeedInput(Exception):
    def __init__(self, question): self.question = question


class ReturnFlow(Exception): pass
class ExitFlow(Exception): pass


def statements(text):
    """Split source at shell statement boundaries, retaining heredocs verbatim."""
    result, buffer, quote, depth, line, start, braces = [], '', '', 0, 1, 1, 0
    index = 0
    while index < len(text):
        c = text[index]
        if not buffer: start = line
        if c == '\\' and quote != "'" and index + 1 < len(text):
            if text[index + 1] == '\n':
                buffer += ' '; line += 1
            else: buffer += text[index:index+2]
            index += 2; continue
        if c == '#' and not quote and not depth and not buffer.strip():
            end = text.find('\n', index)
            if end < 0: break
            index = end; continue
        if quote:
            buffer += c
            if c == quote: quote = ''
        elif c in "'\"": quote = c; buffer += c
        elif text[index:index+2] == '$(':
            depth += 1; buffer += '$('; index += 1
        elif depth:
            buffer += c
            if c == '(': depth += 1
            elif c == ')': depth -= 1
        elif c=='{' and not buffer.endswith('$'):
            braces+=1; buffer+=c
        elif c=='}' and braces:
            braces-=1; buffer+=c
        elif c in ';\n' and not braces:
            # Preserve the whole embedded program; never interpret Python as shell.
            heredoc = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", buffer)
            if c == '\n' and heredoc:
                match = re.search(r'^' + re.escape(heredoc[1]) + r'\s*$', text[index+1:], re.M)
                if not match: raise ValueError('Unterminated heredoc')
                end = index + 1 + match.end()
                buffer += text[index:end]
                line += text[index:end].count('\n')
                result.append((start, buffer.strip())); buffer = ''; index = end; continue
            if buffer.strip(): result.append((start, buffer.strip()))
            buffer = ''
            if c == ';' and text[index:index+2] == ';;':
                result.append((line, ';;')); index += 1
        else: buffer += c
        if c == '\n': line += 1
        index += 1
    if buffer.strip(): result.append((start, buffer.strip()))
    return result


class CommandPreview:
    def __init__(self, settings, inputs=None):
        self.root = settings.scripts_root.resolve()
        self.inputs = inputs or {}
        self.steps, self.trace, self.functions, self.loaded = [], [], {}, set()
        self.config = yaml.safe_load((self.root/'config.yaml').read_text()) or {}
        self.values = {'ROOT':str(self.root), 'CONFIG':str(self.root/'config.yaml'),
                       'CONFIG_DIR':str(self.root), 'PWD':str(self.root)}
        self.budget = 0

    def path(self, path):
        path = Path(path).resolve()
        if not path.is_relative_to(self.root) or path.suffix != '.sh' or path.name.startswith('.env'):
            raise ValueError('Script path must stay inside the repository and end in .sh')
        if path.stat().st_size > 250000: raise ValueError('Script too large')
        return path

    def load(self, path):
        path = self.path(path)
        source=path.read_text()
        # Repository functions use a column-zero closing brace. This avoids
        # confusing nested error-handler groups with the function's closing brace.
        pattern=r'^(\w+)\s*\(\)\s*\{[^\n]*\n(.*?)^\}'
        for match in re.finditer(pattern,source,re.M|re.S):
            offset=source[:match.start(2)].count('\n')
            self.functions[match[1]]=(path,[(n+offset,c) for n,c in statements(match[2])])
        source=re.sub(pattern,lambda m:'\n'*m[0].count('\n'),source,flags=re.M|re.S)
        inline=r'^(\w+)\s*\(\)\s*\{([^\n]*)\}\s*$'
        for match in re.finditer(inline,source,re.M):
            offset=source[:match.start(2)].count('\n')
            self.functions[match[1]]=(path,[(n+offset,c) for n,c in statements(match[2])])
        source=re.sub(inline,'',source,flags=re.M)
        return path, statements(source)

    def question(self, key, label, choices=None, secret=False):
        if key in self.inputs: return self.inputs[key]
        raise NeedInput({'key':key, 'label':label, 'choices':choices, 'secret':secret})

    def value(self, name, path, line):
        if name == 'BASH_SOURCE[0]': return str(path)
        if name not in self.values:
            self.values[name] = self.question('value:'+name, 'Value for '+name,
                                              secret=bool(re.search('TOKEN|SECRET|PASSWORD',name,re.I)))
        return self.values[name]

    def cfg(self, name):
        value = self.config
        for key in name.split('.'): value = value.get(key) if isinstance(value,dict) else None
        if value is None: return ''
        if isinstance(value,bool): return str(value).lower()
        return yaml.safe_dump(value,default_flow_style=True).strip() if isinstance(value,(list,dict)) else str(value)

    def expand(self, code, path, line, raw=False):
        if '\n' in code and re.search(r"<<-?\s*['\"]\w+['\"]",code.split('\n',1)[0]):
            header,body=code.split('\n',1)
            return self.expand(header,path,line)+'\n'+body
        # Resolve cfg and script-relative paths by parsing, never shell evaluation.
        code = re.sub(r'\$\(cfg\s+([\w.]+)\)',lambda m:self.literal(self.cfg(m[1])),code)
        directory = str(path.parent)
        code = code.replace('$(dirname -- "${BASH_SOURCE[0]}")',directory)
        code = code.replace('$(dirname -- "$CONFIG")',str(self.root))
        code = re.sub(r'\$\(cd -- "([^"$]+)" && pwd\)',lambda m:self.literal(str(Path(m[1]).resolve())),code)
        code = re.sub(r'\$\(dirname -- "([^"$]+)"\)',lambda m:self.literal(str(Path(m[1]).parent)),code)
        # Every other substitution is a runtime input, with its source expression.
        while '$(' in code:
            start = code.index('$('); depth, end, quote = 1, start+2, ''
            while end < len(code) and depth:
                c=code[end]
                if quote:
                    if c==quote: quote=''
                elif c in "'\"": quote=c
                elif c=='(': depth+=1
                elif c==')': depth-=1
                end+=1
            if depth: raise ValueError('Unsupported substitution')
            expression=code[start:end]
            value=self.question(f'computed:{path.relative_to(self.root)}:{line}:{expression}',
                                'Enter the output of this runtime expression (not executed): '+expression)
            code=code[:start]+self.literal(value)+code[end:]
        # Substitute only outside single-quoted strings. Literal values are escaped
        # for their shell quote context, so input cannot inject extra commands.
        out, index, quote = '', 0, ''
        while index < len(code):
            c=code[index]
            if c=='\\' and index+1<len(code): out+=code[index:index+2]; index+=2; continue
            if c=="'" and quote!='"': quote='' if quote=="'" else "'"
            elif c=='"' and quote!="'": quote='' if quote=='"' else '"'
            if c=='$' and quote!="'":
                match=re.match(r'\$\{([^}]+)\}|\$(\w+)',code[index:])
                if match:
                    expr=match[1] or match[2]
                    default=re.fullmatch(r'([\w]+):-([^$]*)',expr)
                    name=default[1] if default else expr
                    if default: value=self.values.get(name,'') or default[2]
                    elif re.fullmatch(r'\w+|BASH_SOURCE\[0\]',name): value=self.value(name,path,line)
                    elif re.fullmatch(r'\w+#[\w-]+',name):
                        variable,prefix=name.split('#',1)
                        value=str(self.value(variable,path,line)).removeprefix(prefix)
                    else:
                        value=self.question('expression:'+expr,'Resolved value for ${'+expr+'}')
                    value=str(value)
                    out+=self.literal(value) if quote=='"' else shlex.quote(value)
                    index+=len(match[0]); continue
            out+=c; index+=1
        return out

    @staticmethod
    def literal(value):
        return str(value).replace('\\','\\\\').replace('"','\\"').replace('$','\\$').replace('`','\\`')

    def scalar(self, code, path, line):
        rendered=self.expand(code,path,line)
        words=shlex.split(rendered)
        return ' '.join(words)

    def routes(self):
        path,_=self.load(self.root/'main.sh')
        _,body=self.functions['dispatch']
        _,arms,_=self.case(body,0)
        return [{'action':pattern,'label':pattern.removeprefix('--').replace('-',' ')}
                for patterns,_ in arms for pattern in patterns if pattern.startswith('--')]

    def case(self, units, index):
        expression=re.fullmatch(r'case\s+(.+)\s+in',units[index][1])[1]
        depth, end = 1,index+1
        while end<len(units):
            if units[end][1].startswith('case '): depth+=1
            if units[end][1]=='esac':
                depth-=1
                if depth==0: break
            end+=1
        if depth: raise ValueError('Unsupported case layout')
        arms=[]; patterns=None; body=[]; nested=0
        for line,code in units[index+1:end]:
            if nested==0 and patterns is None:
                match=re.match(r'([^()]+)\)\s*(.*)',code,re.S)
                if not match: raise ValueError('Unsupported case pattern')
                patterns=[p.strip().strip('"\'') for p in match[1].split('|')]
                code=match[2]
                if not code: continue
            if nested==0 and code==';;':
                arms.append((patterns,body)); patterns=None; body=[]; continue
            if code.startswith('case '): nested+=1
            elif code=='esac': nested-=1
            body.append((line,code))
        return expression,arms,end+1

    def walk(self,path,units):
        index=0
        while index<len(units):
            self.budget+=1
            if self.budget>1500: raise ValueError('Route exceeds preview limit')
            line,code=units[index]; index+=1
            if code.startswith('then '): code=code[5:]
            if code.startswith('do '): code=code[3:]
            if not code or code in ('then','do','fi','done','(',')','{','}') or code.startswith('#'): continue
            if code.startswith('case '):
                expression,arms,index=self.case(units,index-1)
                try: selected=self.scalar(expression,path,line)
                except NeedInput:
                    choices=[p for patterns,_ in arms for p in patterns if p not in ('*','')]
                    selected=self.question(f'case:{path.relative_to(self.root)}:{line}', 'Select branch for '+expression, choices)
                for patterns,body in arms:
                    if any(fnmatch.fnmatchcase(selected,p) for p in patterns): self.walk(path,body); break
                continue
            if code.startswith('if '):
                condition=code[3:]; end=index; depth=1; other=None
                while end<len(units):
                    if units[end][1].startswith('if '): depth+=1
                    if units[end][1]=='fi':
                        depth-=1
                        if not depth: break
                    if depth==1 and units[end][1]=='else': other=end
                    if depth==1 and units[end][1].startswith('elif '): raise ValueError('elif requires manual source review')
                    end+=1
                if depth: raise ValueError('Unsupported conditional layout')
                rendered=self.expand(condition,path,line)
                answer=self.condition(rendered)
                if answer is None:
                    answer=self.question(f'if:{path.relative_to(self.root)}:{line}',
                                         'Choose the result of this check (not executed): '+rendered,['true','false'])
                self.walk(path,units[index:(other if other is not None else end)] if answer=='true' else units[other+1:end] if other is not None else [])
                index=end+1; continue
            if code.startswith(('while ','for ','until ','select ')):
                end=index; depth=1
                while end<len(units):
                    if units[end][1].startswith(('while ','for ','until ','select ')): depth+=1
                    if units[end][1]=='done':
                        depth-=1
                        if not depth: break
                    end+=1
                body=units[index:end]
                if depth or not any(c.startswith('read ') for _,c in body):
                    raise ValueError('Non-menu loop requires manual source review; no loop body was silently omitted')
                self.walk(path,body)
                index=end+1; continue
            if code.startswith('local '):
                match=re.fullmatch(r'local\s+(\w+)=(.*)',code,re.S)
                if match: self.values[match[1]]=self.scalar(match[2],path,line)
                continue
            if code.startswith(('set ','umask ','export ','trap ')):
                continue
            assignment=re.fullmatch(r'(\w+)=(.*)',code,re.S)
            if assignment:
                self.values[assignment[1]]=self.scalar(assignment[2],path,line)
                continue
            if code.startswith('read '):
                variable=shlex.split(code.split(' || ')[0])[-1]
                choices=None
                for cursor in range(index,len(units)):
                    if units[cursor][1] in ('case "$'+variable+'" in', 'case "${'+variable+':-}" in'):
                        _,arms,_=self.case(units,cursor)
                        choices=[p for patterns,_ in arms for p in patterns if p not in ('*','')]
                        break
                context='\n'.join(c for _,c in units[max(0,index-10):index-1] if c.startswith(('echo ','printf ')))
                self.values[variable]=self.question(f'read:{path.relative_to(self.root)}:{line}',
                                                   context.replace('\\n','\n')+'\n'+code,
                                                   choices,secret='token' in variable.lower())
                continue
            if re.match(r'^return(?:\s|$)',code): raise ReturnFlow()
            if re.match(r'^exit(?:\s|$)',code): raise ExitFlow()
            if code.startswith(('echo ','printf ','continue','break')): continue
            if '|| {' in code:
                # The command itself is copyable; the function's error handler
                # contains return and is not a standalone terminal command.
                check=code.split('|| {',1)[0].rstrip()
                self.emit(path,line,check)
                if self.condition(self.steps[-1]['command'])=='false':
                    raise ValueError(f'Configuration prerequisite fails at {path.relative_to(self.root)}:{line}; review config.yaml before continuing')
                continue
            if code.startswith(('[[ ','command -v ')):
                self.emit(path,line,code); continue
            if code.startswith('source '):
                target=self.scalar(code[7:],path,line)
                file,body=self.load(target)
                if file not in self.loaded:
                    self.loaded.add(file); self.walk(file,body)
                continue
            rendered=self.expand(code,path,line)
            try: words=shlex.split(rendered)
            except ValueError: raise ValueError('Unsupported command quoting')
            if not words: continue
            if words[0] in self.functions:
                if words[0]=='init_config':
                    self.trace.append({'source':str(path.relative_to(self.root)),'line':line,'call':rendered,
                                       'note':'Configuration values read directly from config.yaml without executing the helper.'})
                    continue
                saved={key:self.values.get(key) for key in ('1','2','3','SCRIPT_DIR')}
                self.values.update({str(i):v for i,v in enumerate(words[1:],1)})
                file,body=self.functions[words[0]]
                self.trace.append({'source':str(path.relative_to(self.root)),'line':line,
                                   'target':str(file.relative_to(self.root)),'call':rendered})
                try: self.walk(file,body)
                except ReturnFlow: pass
                for key,value in saved.items():
                    if value is None: self.values.pop(key,None)
                    else: self.values[key]=value
                continue
            if words[0] in ('bash','exec'):
                offset=2 if words[:2]==['exec','bash'] else 1
                if len(words)>offset and words[offset].endswith('.sh'):
                    file,body=self.load(words[offset])
                    self.trace.append({'source':str(path.relative_to(self.root)),'line':line,
                                       'target':str(file.relative_to(self.root)),'call':rendered})
                    old=dict(self.values)
                    self.values.update({str(i):v for i,v in enumerate(words[offset+1:],1)})
                    self.values['SCRIPT_DIR']=str(file.parent)
                    # Script argument loops don't perform work: route via the final
                    # action case when present. Other script bodies are walked as-is.
                    action=next((w for w in words[offset+1:] if w.startswith('--')),'')
                    action_case=next((i for i,u in reversed(list(enumerate(body))) if u[1]=='case "$ACTION" in'),None)
                    try:
                        if action_case is not None:
                            self.values['ACTION']=action
                            self.values['SCRIPT_DIR']=str(self.root)
                            self.walk(file,body[action_case:])
                        else: self.walk(file,body)
                    except (ExitFlow,ReturnFlow): pass
                    self.values=old
                    continue
            self.steps.append({'source':str(path.relative_to(self.root)),'line':line,'command':rendered})

    def emit(self,path,line,code):
        self.steps.append({'source':str(path.relative_to(self.root)),'line':line,'command':self.expand(code,path,line)})

    @staticmethod
    def condition(rendered):
        try: words=shlex.split(rendered)
        except ValueError: return None
        if len(words)==5 and words[0]=='[[' and words[-1]==']]' and words[2] in ('==','!='):
            matched=fnmatch.fnmatchcase(words[1],words[3])
            return str(matched if words[2]=='==' else not matched).lower()
        if len(words)==4 and words[0]=='[[' and words[-1]==']]' and words[1] in ('-n','-z'):
            return str(bool(words[2]) if words[1]=='-n' else not words[2]).lower()
        return None

    def preview(self,action):
        if action not in {r['action'] for r in self.routes()}: raise HTTPException(422,'Unknown main.sh route')
        self.values['1']=action
        path,body=self.functions['dispatch']
        question=None; limitation=None
        try: self.walk(path,body)
        except (ExitFlow,ReturnFlow): pass
        except NeedInput as exc: question=exc.question
        except (ValueError, OSError, KeyError, IndexError) as exc: limitation=str(exc)
        return {'action':action,'entry_command':shlex.join(['sudo','bash',str(self.root/'main.sh'),action,str(self.root/'config.yaml')]),
                'steps':self.steps,'trace':self.trace,'question':question,'limitation':limitation,
                'complete':not question and not limitation,'mode':'display-only'}
