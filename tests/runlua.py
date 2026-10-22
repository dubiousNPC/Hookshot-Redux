import ctypes, sys
lua = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/liblua5.4.so.0')
for n,a,r in [('luaL_newstate',[],ctypes.c_void_p),('luaL_openlibs',[ctypes.c_void_p],None)]:
    f=getattr(lua,n); f.argtypes=a; f.restype=r
lua.luaL_loadfilex.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
lua.luaL_loadfilex.restype=ctypes.c_int
lua.lua_pcallk.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p]
lua.lua_pcallk.restype=ctypes.c_int
lua.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p]
lua.lua_tolstring.restype=ctypes.c_char_p
lua.lua_createtable.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int]
lua.lua_pushstring.argtypes=[ctypes.c_void_p,ctypes.c_char_p]; lua.lua_pushstring.restype=ctypes.c_void_p
lua.lua_rawseti.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_longlong]
lua.lua_setglobal.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
L=lua.luaL_newstate(); lua.luaL_openlibs(L)
# arg table
lua.lua_createtable(L,len(sys.argv)-2,0)
for i,v in enumerate(sys.argv[2:],start=1):
    lua.lua_pushstring(L,v.encode()); lua.lua_rawseti(L,-2,i)
lua.lua_setglobal(L,b'arg')
if lua.luaL_loadfilex(L,sys.argv[1].encode(),b't')!=0:
    print('load error:',lua.lua_tolstring(L,-1,None).decode()); sys.exit(1)
if lua.lua_pcallk(L,0,-1,0,None,None)!=0:
    print('run error:',lua.lua_tolstring(L,-1,None).decode()); sys.exit(1)
