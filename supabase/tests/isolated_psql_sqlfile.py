"""Owned UTF-8 SQL files for the disposable harness; no database operations."""
import hashlib
import os
from pathlib import Path
import re
import tempfile


def statement_heads(sql):
    """Classify top-level statements, skipping comments, strings and DO bodies.

    This is not SQL validation. Actual compilation/errors still belong to psql.
    """
    plain=[];i=0
    while i<len(sql):
        if sql.startswith('--',i):
            end=sql.find('\n',i);i=len(sql) if end<0 else end+1;plain.append(' ')
        elif sql.startswith('/*',i):
            depth=1;i+=2
            while i<len(sql) and depth:
                if sql.startswith('/*',i):depth+=1;i+=2
                elif sql.startswith('*/',i):depth-=1;i+=2
                else:i+=1
            plain.append(' ')
        elif sql[i] in "'\"":
            quote=sql[i];escaped=quote=="'" and i>0 and sql[i-1] in 'Ee' and (i<2 or not sql[i-2].isalnum())
            i+=1
            while i<len(sql):
                if escaped and sql[i]=='\\':i+=2
                elif sql[i]==quote:
                    i+=1
                    if i<len(sql) and sql[i]==quote:i+=1
                    else:break
                else:i+=1
            plain.append(' ')
        elif sql[i]=='$' and (match:=re.match(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$',sql[i:])):
            delimiter=match.group(0);end=sql.find(delimiter,i+len(delimiter))
            i=len(sql) if end<0 else end+len(delimiter);plain.append(' ')
        else:plain.append(sql[i]);i+=1
    return [re.findall(r'[A-Za-z_]+',part.upper())[:3] for part in ''.join(plain).split(';') if part.strip()]


def single_transaction(sql):
    heads=statement_heads(sql)
    controls={'BEGIN','START','COMMIT','END','ROLLBACK','ABORT'}
    if any(h and h[0] in controls for h in heads):
        if not heads or heads[0][0] not in ('BEGIN','START') or heads[-1][0] not in ('COMMIT','END','ROLLBACK','ABORT'):
            raise ValueError('INCOMPLETE_EXPLICIT_TRANSACTION_BATCH')
        return False  # preserve the existing BEGIN/COMMIT exactly
    if len(heads)<=1:return False  # permits standalone CREATE/DROP DATABASE
    if any(h[:2] in (['CREATE','DATABASE'],['DROP','DATABASE']) for h in heads):
        raise ValueError('DATABASE_DDL_MUST_BE_A_STANDALONE_COMMAND')
    # -c sends an unwrapped multi-statement string in ONE implicit transaction.
    # -f otherwise commits each statement: preserve that atomicity with -1.
    return True


class SqlFiles:
    def __init__(self,root):
        self.root=Path(root).resolve()
        self.root.mkdir(exist_ok=True)
        self.owned={}

    def command(self,args):
        if args.count('-c')!=1 or '-f' in args or '--file' in args:
            raise ValueError('ONE_SQL_INPUT_REQUIRED')
        index=args.index('-c')
        if index!=len(args)-2:raise ValueError('UNEXPECTED_ARGUMENTS_AFTER_SQL')
        sql=args[index+1]
        if re.search(r'^\s*\\',sql,re.M):raise ValueError('PSQL_META_COMMANDS_FORBIDDEN')
        atomic=single_transaction(sql)
        fd,name=tempfile.mkstemp(prefix='sql-',suffix='.sql',dir=self.root)
        path=Path(name)
        try:
            # Close before psql opens it: Windows cannot reopen a delete-on-close
            # NamedTemporaryFile. No BOM or newline conversion is introduced.
            with os.fdopen(fd,'w',encoding='utf-8',newline='') as f:f.write(sql)
            self.owned[path.resolve()]=hashlib.sha256(sql.encode('utf-8')).hexdigest()
            return args[:index]+(['--single-transaction'] if atomic else [])+['-f',str(path)]
        except BaseException:
            path.unlink(missing_ok=True)
            raise

    def path(self,args):
        if args.count('-f')!=1 or '-c' in args:raise ValueError('OWNED_SQL_FILE_REQUIRED')
        path=Path(args[args.index('-f')+1]).resolve()
        if path.parent!=self.root or path not in self.owned or not path.is_file():
            raise ValueError('UNOWNED_SQL_FILE')
        return path

    def remove(self,args):
        if '-f' not in args:return
        path=Path(args[args.index('-f')+1]).resolve()
        if path not in self.owned:return  # never delete an externally supplied file
        path.unlink(missing_ok=True)
        self.owned.pop(path)

    def cleanup(self):
        for path in list(self.owned):self.remove(['-f',str(path)])
