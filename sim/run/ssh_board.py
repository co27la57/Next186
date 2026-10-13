import paramiko,sys
cmd=' '.join(sys.argv[1:])
c=paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy()); c.connect('172.25.82.54',22,'root','1133',look_for_keys=False,allow_agent=False,timeout=10,banner_timeout=10,auth_timeout=10)
try:
    _,o,e=c.exec_command(cmd,timeout=30)
    print(o.read().decode('utf-8','replace'),end='')
    err=e.read().decode('utf-8','replace')
    if err: print('--- stderr ---\n'+err,end='')
finally:
    c.close()

