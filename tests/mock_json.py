"""Minimal JSON runtime for exercising the actual rpcd shell plugin locally."""
import json, os, sys
obj=json.loads(os.environ.get('JSON_TEST_DATA','{}'))
args=sys.argv[1:]
cmd=args[0]
if cmd=='valid':
    sys.exit(0 if isinstance(obj,dict) else 1)
elif cmd=='keys':
    print(' '.join(obj))
elif cmd=='get':
    if args[1] not in obj: sys.exit(1)
    value=obj[args[1]]
    print(value if isinstance(value,str) else json.dumps(value))
elif cmd=='type':
    value=obj.get(args[1]); print('string' if isinstance(value,str) else 'other')
elif cmd=='add':
    target=obj
    path=os.environ.get('JSON_TEST_PATH','')
    if path: target=obj.setdefault(path,{})
    target[args[2]]=args[3] if args[1]=='string' else args[3]=='1'
    print(json.dumps(obj))
