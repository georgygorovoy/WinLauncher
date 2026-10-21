/* Local WinRT picker compatibility for Minecraft Bedrock. GPL-3.0-or-later.
 * ABI layouts follow Microsoft's Windows SDK / Windows App SDK metadata.
 * Extends the project's October 10 local import/export bridge. No game binary
 * changes. Dialogs run through Wine's common-dialog APIs on the caller apartment.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
#include <objbase.h>
#include <roerrorapi.h>
#include <commdlg.h>
#include <winstring.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "ids.h"

typedef struct Object Object;
typedef struct Face { const void **vt; Object *o; } Face;
struct Object {
    Face main, other;
    LONG refs;
    int kind, modern;
    GUID iid;
    HWND window;
    HSTRING strings[4];
    UINT32 view, location, count, capacity;
    HSTRING *keys;
    IUnknown **values;
    IUnknown *child, *result, *handler;
    HRESULT error;
    SRWLOCK lock;
    LONG closed, handler_assigned;
};
enum { FACTORY_SAVE, FACTORY_OPEN, FACTORY_UWP_OPEN, FACTORY_FILE,
       SAVE, OPEN, UWP_OPEN, VECTOR, MAP, FILE_RESULT, ASYNC };
static const void *factory_save_vt[7], *factory_open_vt[7], *save_vt[20], *open_vt[15];
static const void *vector_vt[18], *view_vt[10], *map_vt[13], *file_vt[18], *item_vt[16], *pick_vt[7], *async_vt[9], *info_vt[11], *window_vt[4], *uwp_open_vt[17], *file_statics_vt[12];
static Object *create(int kind);
static ULONG WINAPI addref(Face *f) { return InterlockedIncrement(&f->o->refs); }
static ULONG WINAPI release(Face *f) {
    Object *o=f->o; LONG n=InterlockedDecrement(&o->refs); UINT32 i;
    if(n) return n;
    for(i=0;i<4;i++) WindowsDeleteString(o->strings[i]);
    for(i=0;i<o->count;i++) { WindowsDeleteString(o->keys[i]); if(o->values && o->values[i]) IUnknown_Release(o->values[i]); }
    if(o->keys) HeapFree(GetProcessHeap(),0,o->keys);
    if(o->values) HeapFree(GetProcessHeap(),0,o->values);
    if(o->child) IUnknown_Release(o->child);
    if(o->result) IUnknown_Release(o->result);
    if(o->handler) IUnknown_Release(o->handler);
    HeapFree(GetProcessHeap(),0,o); return 0;
}
static HRESULT WINAPI query(Face *f, REFIID iid, void **out) {
    Object *o=f->o;
    if(!out) return E_POINTER; *out=NULL;
    if(IsEqualGUID(iid,&ID_IUnknown)||IsEqualGUID(iid,&ID_Inspectable)||IsEqualGUID(iid,&o->iid)) *out=&o->main;
    else if ((o->kind==SAVE||o->kind==OPEN||o->kind==UWP_OPEN)&&IsEqualGUID(iid,&ID_InitWindow)) *out=&o->other;
    else if(o->kind==FILE_RESULT&&!o->modern&&IsEqualGUID(iid,&ID_StorageItem)) *out=&o->other;
    else if(o->kind==VECTOR&&IsEqualGUID(iid,&ID_VectorView)) *out=&o->other;
    else if(o->kind==ASYNC&&IsEqualGUID(iid,&ID_AsyncInfo)) *out=&o->other;
    else if(o->kind==FACTORY_OPEN&&IsEqualGUID(iid,&ID_OpenFactory)) *out=&o->other;
    else if(o->kind==FACTORY_FILE&&IsEqualGUID(iid,&ID_StorageFileStatics)) *out=&o->other;
    else {
        fprintf(stderr,"[bedrock-pickers] unsupported interface kind=%d iid=%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",o->kind,iid->Data1,iid->Data2,iid->Data3,iid->Data4[0],iid->Data4[1],iid->Data4[2],iid->Data4[3],iid->Data4[4],iid->Data4[5],iid->Data4[6],iid->Data4[7]);
        return E_NOINTERFACE;
    }
    addref(f);return S_OK;
}
static HRESULT WINAPI iids(Face *f,ULONG *n,GUID **out) {
    GUID supported[2]; UINT32 count=1; Object *o=f->o;
    if(!n||!out)return E_POINTER;*n=0;*out=NULL;supported[0]=o->iid;
    if(o->kind==FACTORY_OPEN)supported[count++]=ID_OpenFactory;
    if(o->kind==FACTORY_FILE)supported[count++]=ID_StorageFileStatics;
    if(o->kind==FILE_RESULT&&!o->modern)supported[count++]=ID_StorageItem;
    if(o->kind==VECTOR)supported[count++]=ID_VectorView;
    if(o->kind==ASYNC)supported[count++]=ID_AsyncInfo;
    *out=CoTaskMemAlloc(count*sizeof(GUID));if(!*out)return E_OUTOFMEMORY;
    memcpy(*out,supported,count*sizeof(GUID));*n=count;return S_OK;
}
static HRESULT WINAPI classname(Face *f,HSTRING *out) {
    const WCHAR *s=L"Bedrock.PickerCompatibility";
    if(f->o->kind==SAVE)s=L"Windows.Storage.Pickers.FileSavePicker";
    if(f->o->kind==OPEN)s=L"Microsoft.Windows.Storage.Pickers.FileOpenPicker";
    if(f->o->kind==UWP_OPEN)s=L"Windows.Storage.Pickers.FileOpenPicker";
    if(f->o->kind==FILE_RESULT)s=f->o->modern?L"Microsoft.Windows.Storage.Pickers.PickFileResult":L"Windows.Storage.StorageFile";
    return WindowsCreateString(s,lstrlenW(s),out);
}
static HRESULT WINAPI trust(Face *f,int *out) {if(!out)return E_POINTER;*out=0;return S_OK;}
#define BASE query,addref,release,iids,classname,trust
static HRESULT WINAPI unsupported(Face *f) {return E_NOTIMPL;}
static HRESULT WINAPI unsupported_out(Face *f,void **out) {if(!out)return E_POINTER;*out=NULL;return E_NOTIMPL;}
static HRESULT dup(HSTRING src,HSTRING *out) {if(!out)return E_POINTER;*out=NULL;return WindowsDuplicateString(src,out);}
static HRESULT put(HSTRING *slot,HSTRING value) {HSTRING s=NULL;HRESULT hr=WindowsDuplicateString(value,&s);if(FAILED(hr))return hr;WindowsDeleteString(*slot);*slot=s;return S_OK;}
#define STRING_PROP(N) static HRESULT WINAPI get##N(Face*f,HSTRING*out){return dup(f->o->strings[N],out);} static HRESULT WINAPI set##N(Face*f,HSTRING v){return put(&f->o->strings[N],v);}
STRING_PROP(0) STRING_PROP(1) STRING_PROP(2) STRING_PROP(3)
static HRESULT WINAPI get_view(Face*f,UINT32*out){if(!out)return E_POINTER;*out=f->o->view;return S_OK;}
static HRESULT WINAPI set_view(Face*f,UINT32 v){if(v>1)return E_INVALIDARG;f->o->view=v;return S_OK;}
static HRESULT WINAPI get_location(Face*f,UINT32*out){if(!out)return E_POINTER;*out=f->o->location;return S_OK;}
static HRESULT WINAPI set_location(Face*f,UINT32 v){f->o->location=v;return S_OK;}
static HRESULT WINAPI get_child(Face*f,IUnknown**out){if(!out)return E_POINTER;*out=f->o->child;if(*out)IUnknown_AddRef(*out);return S_OK;}
static HRESULT WINAPI initialize(Face*f,HWND w){f->o->window=w;return S_OK;}
static const void *window_vt[]={query,addref,release,initialize};

static BOOL reserve(Object*o,UINT32 n) {
    UINT32 cap;HSTRING *keys;IUnknown **values=NULL;
    if(n<=o->capacity)return TRUE;
    if(n>65536)return FALSE;
    cap=o->capacity?o->capacity*2:8;if(cap<n)cap=n;
    keys=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,cap*sizeof(*keys));if(!keys)return FALSE;
    if(o->kind==MAP){values=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,cap*sizeof(*values));if(!values){HeapFree(GetProcessHeap(),0,keys);return FALSE;}}
    if(o->count){memcpy(keys,o->keys,o->count*sizeof(*keys));if(values)memcpy(values,o->values,o->count*sizeof(*values));}
    if(o->keys)HeapFree(GetProcessHeap(),0,o->keys);if(o->values)HeapFree(GetProcessHeap(),0,o->values);
    o->keys=keys;o->values=values;o->capacity=cap;return TRUE;
}
static BOOL equal_string(HSTRING a,HSTRING b){INT32 r=1;return SUCCEEDED(WindowsCompareStringOrdinal(a,b,&r))&&!r;}
static HRESULT WINAPI size(Face*f,UINT32*out){if(!out)return E_POINTER;*out=f->o->count;return S_OK;}
static HRESULT WINAPI clear(Face*f){Object*o=f->o;UINT32 i;for(i=0;i<o->count;i++){WindowsDeleteString(o->keys[i]);if(o->values&&o->values[i])IUnknown_Release(o->values[i]);}o->count=0;return S_OK;}
static HRESULT WINAPI vec_get(Face*f,UINT32 i,HSTRING*out){if(!out)return E_POINTER;*out=NULL;if(i>=f->o->count)return E_BOUNDS;return dup(f->o->keys[i],out);}
static HRESULT WINAPI vec_view(Face*f,void**out){return query(f,&ID_VectorView,out);}
static HRESULT WINAPI vec_index(Face*f,HSTRING v,UINT32*i,BOOLEAN*found){UINT32 n;if(!i||!found)return E_POINTER;*i=0;*found=FALSE;for(n=0;n<f->o->count;n++)if(equal_string(v,f->o->keys[n])){*i=n;*found=TRUE;break;}return S_OK;}
static HRESULT WINAPI vec_set(Face*f,UINT32 i,HSTRING v){if(i>=f->o->count)return E_BOUNDS;return put(&f->o->keys[i],v);}
static HRESULT WINAPI vec_insert(Face*f,UINT32 i,HSTRING v){Object*o=f->o;HSTRING s=NULL;HRESULT hr;if(i>o->count)return E_BOUNDS;hr=WindowsDuplicateString(v,&s);if(FAILED(hr))return hr;if(!reserve(o,o->count+1)){WindowsDeleteString(s);return E_OUTOFMEMORY;}memmove(o->keys+i+1,o->keys+i,(o->count-i)*sizeof(s));o->keys[i]=s;o->count++;return S_OK;}
static HRESULT WINAPI vec_remove(Face*f,UINT32 i){Object*o=f->o;if(i>=o->count)return E_BOUNDS;WindowsDeleteString(o->keys[i]);memmove(o->keys+i,o->keys+i+1,(o->count-i-1)*sizeof(HSTRING));o->count--;return S_OK;}
static HRESULT WINAPI vec_append(Face*f,HSTRING v){return vec_insert(f,f->o->count,v);}
static HRESULT WINAPI vec_pop(Face*f){return f->o->count?vec_remove(f,f->o->count-1):E_BOUNDS;}
static HRESULT WINAPI vec_many(Face*f,UINT32 start,UINT32 cap,HSTRING*out,UINT32*actual){UINT32 i,n;HRESULT hr;if(!actual||(!out&&cap))return E_POINTER;*actual=0;if(start>f->o->count)return E_BOUNDS;n=f->o->count-start;if(n>cap)n=cap;for(i=0;i<n;i++)out[i]=NULL;for(i=0;i<n;i++){hr=dup(f->o->keys[start+i],out+i);if(FAILED(hr)){while(i){--i;WindowsDeleteString(out[i]);out[i]=NULL;}return hr;}}*actual=n;return S_OK;}
static HRESULT WINAPI vec_replace(Face*f,UINT32 n,HSTRING*items){UINT32 i;HRESULT hr;Object*copy;if(n&&!items)return E_POINTER;copy=create(VECTOR);if(!copy)return E_OUTOFMEMORY;for(i=0;i<n;i++)if(FAILED(hr=vec_append(&copy->main,items[i]))){release(&copy->main);return hr;}clear(f);if(f->o->keys)HeapFree(GetProcessHeap(),0,f->o->keys);f->o->keys=copy->keys;f->o->count=copy->count;f->o->capacity=copy->capacity;copy->keys=NULL;copy->count=0;release(&copy->main);return S_OK;}
static const void *vector_vt[]={BASE,vec_get,size,vec_view,vec_index,vec_set,vec_insert,vec_remove,vec_append,vec_pop,clear,vec_many,vec_replace};
static const void *view_vt[]={BASE,vec_get,size,vec_index,vec_many};
static int map_index(Object*o,HSTRING key){UINT32 i;for(i=0;i<o->count;i++)if(equal_string(o->keys[i],key))return i;return -1;}
static HRESULT WINAPI map_lookup(Face*f,HSTRING key,IUnknown**out){int i;if(!out)return E_POINTER;*out=NULL;i=map_index(f->o,key);if(i<0)return E_BOUNDS;*out=f->o->values[i];IUnknown_AddRef(*out);return S_OK;}
static HRESULT WINAPI map_has(Face*f,HSTRING key,BOOLEAN*out){if(!out)return E_POINTER;*out=map_index(f->o,key)>=0;return S_OK;}
static HRESULT WINAPI map_insert(Face*f,HSTRING key,IUnknown*value,BOOLEAN*replaced){Object*o=f->o;int i;HRESULT hr;if(!value||!replaced)return E_POINTER;i=map_index(o,key);*replaced=i>=0;if(i<0){if(!reserve(o,o->count+1))return E_OUTOFMEMORY;i=o->count;hr=dup(key,&o->keys[i]);if(FAILED(hr))return hr;o->count++;}IUnknown_AddRef(value);if(*replaced)IUnknown_Release(o->values[i]);o->values[i]=value;return S_OK;}
static HRESULT WINAPI map_remove(Face*f,HSTRING key){Object*o=f->o;int i=map_index(o,key);if(i<0)return E_BOUNDS;WindowsDeleteString(o->keys[i]);IUnknown_Release(o->values[i]);memmove(o->keys+i,o->keys+i+1,(o->count-i-1)*sizeof(HSTRING));memmove(o->values+i,o->values+i+1,(o->count-i-1)*sizeof(IUnknown*));o->count--;return S_OK;}
static const void *map_vt[]={BASE,map_lookup,size,map_has,unsupported,map_insert,map_remove,clear};

static HRESULT WINAPI file_type(Face*f,HSTRING*out){const WCHAR*p=WindowsGetStringRawBuffer(f->o->strings[0],NULL),*last=wcsrchr(p,L'\\'),*dot; p=last?last+1:p;dot=wcsrchr(p,L'.');return WindowsCreateString(dot?dot:L"",dot?lstrlenW(dot):0,out);}
static HRESULT WINAPI file_name(Face*f,HSTRING*out){const WCHAR*p=WindowsGetStringRawBuffer(f->o->strings[0],NULL),*last=wcsrchr(p,L'\\');p=last?last+1:p;return WindowsCreateString(p,lstrlenW(p),out);}
static HRESULT WINAPI file_attributes(Face*f,UINT32*out){if(!out)return E_POINTER;*out=GetFileAttributesW(WindowsGetStringRawBuffer(f->o->strings[0],NULL));if(*out==INVALID_FILE_ATTRIBUTES)*out=0;return S_OK;}
static HRESULT WINAPI file_created(Face*f,INT64*out){WIN32_FILE_ATTRIBUTE_DATA data;ULARGE_INTEGER t;if(!out)return E_POINTER;*out=0;if(!GetFileAttributesExW(WindowsGetStringRawBuffer(f->o->strings[0],NULL),GetFileExInfoStandard,&data))return HRESULT_FROM_WIN32(GetLastError());t.LowPart=data.ftCreationTime.dwLowDateTime;t.HighPart=data.ftCreationTime.dwHighDateTime;*out=t.QuadPart;return S_OK;}
static HRESULT WINAPI file_is_type(Face*f,UINT32 t,BOOLEAN*out){if(!out)return E_POINTER;*out=t==1;return S_OK;}
static const void *file_vt[]={BASE,file_type,get1,unsupported,unsupported,unsupported,unsupported,unsupported,unsupported,unsupported,unsupported,unsupported,unsupported};
static const void *item_vt[]={BASE,unsupported,unsupported,unsupported,unsupported,unsupported,file_name,get0,file_attributes,file_created,file_is_type};
static const void *pick_vt[]={BASE,get0};

/* The modal dialog completes before returning. Invoke outside the lock: C++/WinRT
 * continuations may reenter GetResults or Close and release their operation. */
static HRESULT WINAPI completed_put(Face*f,IUnknown*handler){
    Object*o=f->o;typedef HRESULT(WINAPI*Invoke)(IUnknown*,Face*,int);
    if(!handler)return E_POINTER;
    AcquireSRWLockExclusive(&o->lock);
    if(o->closed){ReleaseSRWLockExclusive(&o->lock);return RO_E_CLOSED;}
    if(o->handler_assigned){ReleaseSRWLockExclusive(&o->lock);return E_ILLEGAL_DELEGATE_ASSIGNMENT;}
    o->handler_assigned=1;IUnknown_AddRef(handler);o->handler=handler;
    IUnknown_AddRef(handler);addref(f);
    ReleaseSRWLockExclusive(&o->lock);
    ((Invoke)(*(void***)handler)[3])(handler,&o->main,FAILED(o->error)?3:1);
    IUnknown_Release(handler);release(f);return S_OK;
}
static HRESULT WINAPI completed_get(Face*f,IUnknown**out){Object*o=f->o;HRESULT hr=S_OK;if(!out)return E_POINTER;*out=NULL;AcquireSRWLockShared(&o->lock);if(o->closed)hr=RO_E_CLOSED;else{*out=o->handler;if(*out)IUnknown_AddRef(*out);}ReleaseSRWLockShared(&o->lock);return hr;}
static HRESULT WINAPI results(Face*f,IUnknown**out){Object*o=f->o;HRESULT hr;if(!out)return E_POINTER;*out=NULL;AcquireSRWLockShared(&o->lock);hr=o->closed?RO_E_CLOSED:o->error;if(SUCCEEDED(hr)){*out=o->result;if(*out)IUnknown_AddRef(*out);}ReleaseSRWLockShared(&o->lock);return hr;}
static HRESULT WINAPI async_id(Face*f,UINT32*out){if(!out)return E_POINTER;*out=1;return InterlockedCompareExchange(&f->o->closed,0,0)?RO_E_CLOSED:S_OK;}
static HRESULT WINAPI async_status(Face*f,int*out){if(!out)return E_POINTER;*out=FAILED(f->o->error)?3:1;return InterlockedCompareExchange(&f->o->closed,0,0)?RO_E_CLOSED:S_OK;}
static HRESULT WINAPI async_error(Face*f,HRESULT*out){if(!out)return E_POINTER;*out=f->o->error;return InterlockedCompareExchange(&f->o->closed,0,0)?RO_E_CLOSED:S_OK;}
static HRESULT WINAPI async_cancel(Face*f){return InterlockedCompareExchange(&f->o->closed,0,0)?RO_E_CLOSED:S_OK;}
static HRESULT WINAPI async_close(Face*f){Object*o=f->o;IUnknown *handler,*result;AcquireSRWLockExclusive(&o->lock);InterlockedExchange(&o->closed,1);handler=o->handler;result=o->result;o->handler=o->result=NULL;ReleaseSRWLockExclusive(&o->lock);if(handler)IUnknown_Release(handler);if(result)IUnknown_Release(result);return S_OK;}
static const void *async_vt[]={BASE,completed_put,completed_get,results};
static const void *info_vt[]={BASE,async_id,async_status,async_error,async_cancel,async_close};

/* Typed completed operations are shared by modern selection and StorageFile
 * conversion. An error remains an async error rather than a non-null fake file. */
static HRESULT operation(HSTRING path,BOOL modern,HRESULT error,void**out){
    Object *a,*r;if(!out)return E_POINTER;*out=NULL;
    a=create(ASYNC);if(!a)return E_OUTOFMEMORY;a->iid=modern?ID_AsyncPick:ID_AsyncFile;a->error=error;
    if(path&&SUCCEEDED(error)){
        r=create(FILE_RESULT);if(!r){release(&a->main);return E_OUTOFMEMORY;}
        r->modern=modern;r->iid=modern?ID_PickResult:ID_StorageFile;r->main.vt=modern?pick_vt:file_vt;
        a->error=put(&r->strings[0],path);a->result=(IUnknown*)&r->main;
    }
    *out=&a->main;return S_OK;
}

#define FILTER_CAPACITY 65536
typedef struct Filter {WCHAR *text;UINT32 used;WCHAR extension[256];BOOL default_recorded;} Filter;
static HRESULT filter_text(Filter*f,const WCHAR*s,UINT32 n){if(n>=FILTER_CAPACITY-f->used)return E_INVALIDARG;memcpy(f->text+f->used,s,n*sizeof(WCHAR));f->used+=n;f->text[f->used]=0;return S_OK;}
static HRESULT filter_string(Filter*f,HSTRING s){UINT32 n;const WCHAR*p=WindowsGetStringRawBuffer(s,&n);if(!n||wcslen(p)!=n)return E_INVALIDARG;return filter_text(f,p,n);}
static HRESULT filter_extensions(Filter*f,IUnknown*value){
    typedef HRESULT(WINAPI*Size)(void*,UINT32*);typedef HRESULT(WINAPI*Get)(void*,UINT32,HSTRING*);
    IUnknown*vector=NULL;HSTRING ext=NULL;UINT32 count,i,n,j;const WCHAR*p;HRESULT hr;
    if(!value)return E_INVALIDARG;
    hr=IUnknown_QueryInterface(value,&ID_Vector,(void**)&vector);if(FAILED(hr))return hr;
    hr=((Size)(*(void***)vector)[7])(vector,&count);
    if(SUCCEEDED(hr)&&(!count||count>1024))hr=E_INVALIDARG;
    for(i=0;SUCCEEDED(hr)&&i<count;i++){
        hr=((Get)(*(void***)vector)[6])(vector,i,&ext);if(FAILED(hr))break;
        p=WindowsGetStringRawBuffer(ext,&n);
        if(!n||n>=256||wcslen(p)!=n||!((n==1&&p[0]==L'*')||(n>1&&p[0]==L'.')))hr=E_INVALIDARG;
        for(j=1;SUCCEEDED(hr)&&j<n;j++)if(p[j]<=L' '||wcschr(L"\\/:;*?\"<>|",p[j]))hr=E_INVALIDARG;
        if(SUCCEEDED(hr)&&i)hr=filter_text(f,L";",1);
        if(SUCCEEDED(hr))hr=filter_text(f,p[0]==L'*'?L"*.*":L"*",p[0]==L'*'?3:1);
        if(SUCCEEDED(hr)&&p[0]!=L'*')hr=filter_text(f,p,n);
        if(SUCCEEDED(hr)&&!f->default_recorded){if(p[0]==L'.')lstrcpynW(f->extension,p+1,256);f->default_recorded=TRUE;}
        WindowsDeleteString(ext);ext=NULL;
    }
    IUnknown_Release(vector);return hr;
}
static HRESULT make_filter(Object*o,Filter*f){
    Object*choices=(Object*)((Face*)o->child)->o;UINT32 i;HRESULT hr=S_OK;
    ZeroMemory(f,sizeof(*f));f->text=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,FILTER_CAPACITY*sizeof(WCHAR));if(!f->text)return E_OUTOFMEMORY;
    if(o->kind==SAVE){
        if(!choices->count)hr=E_INVALIDARG;
        for(i=0;SUCCEEDED(hr)&&i<choices->count;i++){
            hr=filter_string(f,choices->keys[i]);if(SUCCEEDED(hr))hr=filter_text(f,L"\0",1);
            if(SUCCEEDED(hr))hr=filter_extensions(f,choices->values[i]);
            if(SUCCEEDED(hr))hr=filter_text(f,L"\0",1);
        }
    }else{
        hr=filter_text(f,L"Supported files\0",16);
        if(SUCCEEDED(hr))hr=filter_extensions(f,o->child);
        if(SUCCEEDED(hr))hr=filter_text(f,L"\0",1);
    }
    if(SUCCEEDED(hr))hr=filter_text(f,L"\0",1);
    if(FAILED(hr)){HeapFree(GetProcessHeap(),0,f->text);f->text=NULL;}
    return hr;
}

static BOOL CALLBACK find_window(HWND w,LPARAM param){DWORD pid;GetWindowThreadProcessId(w,&pid);if(pid==GetCurrentProcessId()&&IsWindowVisible(w)&&!GetWindow(w,GW_OWNER)){*(HWND*)param=w;return FALSE;}return TRUE;}
static HRESULT WINAPI pick(Face*f,void**out){
    Object*o=f->o;OPENFILENAMEW dialog;WCHAR *path;BOOL ok;DWORD err;HWND owner=o->window;Filter filter;HRESULT hr;HSTRING selected=NULL;const WCHAR*extension;UINT32 length,j;
    if(!out)return E_POINTER;*out=NULL;
    hr=make_filter(o,&filter);if(FAILED(hr))return hr;
    path=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,32768*sizeof(WCHAR));if(!path){HeapFree(GetProcessHeap(),0,filter.text);return E_OUTOFMEMORY;}
    if(o->kind==SAVE){UINT32 length;const WCHAR*name=WindowsGetStringRawBuffer(o->strings[3],&length);if(length>=32768||wcslen(name)!=length){hr=E_INVALIDARG;goto done;}lstrcpynW(path,name,32768);}
    if(!IsWindow(owner))EnumWindows(find_window,(LPARAM)&owner);
    ZeroMemory(&dialog,sizeof(dialog));dialog.lStructSize=sizeof(dialog);dialog.hwndOwner=owner;dialog.lpstrFile=path;dialog.nMaxFile=32768;dialog.lpstrFilter=filter.text;dialog.nFilterIndex=1;
    dialog.lpstrTitle=o->kind==SAVE?L"Save file":L"Open file";
    extension=WindowsGetStringRawBuffer(o->strings[2],&length);
    if(length>=256||wcslen(extension)!=length){hr=E_INVALIDARG;goto done;}
    if(*extension==L'.')extension++;
    for(j=0;extension[j];j++)if(extension[j]<=L' '||wcschr(L"\\/:;*?\"<>|",extension[j])){hr=E_INVALIDARG;goto done;}
    dialog.lpstrDefExt=o->kind==SAVE?(*extension?extension:filter.extension):NULL;
    dialog.Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|OFN_HIDEREADONLY|(o->kind==SAVE?OFN_OVERWRITEPROMPT:OFN_FILEMUSTEXIST);
    ok=o->kind==SAVE?GetSaveFileNameW(&dialog):GetOpenFileNameW(&dialog);err=ok?0:CommDlgExtendedError();
    hr=err?E_FAIL:S_OK;
    if(ok){
        if(o->kind==SAVE){HANDLE file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);if(file==INVALID_HANDLE_VALUE)hr=HRESULT_FROM_WIN32(GetLastError());else CloseHandle(file);}
        if(SUCCEEDED(hr))hr=WindowsCreateString(path,lstrlenW(path),&selected);
    }
    hr=operation(selected,o->kind==OPEN,hr,out);
done:
    WindowsDeleteString(selected);HeapFree(GetProcessHeap(),0,path);HeapFree(GetProcessHeap(),0,filter.text);return hr;
}
static HRESULT WINAPI suggested_file_get(Face*f,void**out){if(!out)return E_POINTER;*out=NULL;return S_OK;}
static HRESULT WINAPI suggested_file_set(Face*f,IUnknown*v){return v?E_NOTIMPL:S_OK;}
static const void *save_vt[]={BASE,get0,set0,get_location,set_location,get1,set1,get_child,get2,set2,suggested_file_get,suggested_file_set,get3,set3,pick};
static const void *open_vt[]={BASE,get_view,set_view,get_location,set_location,get1,set1,get_child,pick,unsupported_out};
static const void *uwp_open_vt[]={BASE,get_view,set_view,get0,set0,get_location,set_location,get1,set1,get_child,pick,unsupported_out};
static HRESULT WINAPI activate(Face*f,void**out){Object*o;int kind;if(!out)return E_POINTER;*out=NULL;if(f->o->kind==FACTORY_FILE)return E_NOTIMPL;kind=f->o->kind==FACTORY_SAVE?SAVE:f->o->kind==FACTORY_UWP_OPEN?UWP_OPEN:OPEN;o=create(kind);if(!o)return E_OUTOFMEMORY;*out=&o->main;return S_OK;}
static HRESULT WINAPI create_open(Face*f,UINT64 window,void**out){HRESULT hr=activate(f,out);if(SUCCEEDED(hr))((Face*)*out)->o->window=(HWND)(ULONG_PTR)window;return hr;}
static const void *factory_save_vt[]={BASE,activate};
static const void *factory_open_vt[]={BASE,create_open};
static HRESULT WINAPI file_from_path(Face*f,HSTRING path,void**out){
    UINT32 n;const WCHAR*p;DWORD attributes;HRESULT hr=S_OK;
    if(!out)return E_POINTER;*out=NULL;p=WindowsGetStringRawBuffer(path,&n);
    if(!n||wcslen(p)!=n||!((n>=3&&p[1]==L':'&&p[2]==L'\\')||(n>=3&&p[0]==L'\\'&&p[1]==L'\\')))return E_INVALIDARG;
    attributes=GetFileAttributesW(p);
    if(attributes==INVALID_FILE_ATTRIBUTES)hr=HRESULT_FROM_WIN32(GetLastError());
    else if(attributes&FILE_ATTRIBUTE_DIRECTORY)hr=HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    return operation(path,FALSE,hr,out);
}
static HRESULT WINAPI streamed_create(Face*f,HSTRING name,IUnknown*requested,IUnknown*thumbnail,void**out){return unsupported_out(f,out);}
static HRESULT WINAPI streamed_replace(Face*f,IUnknown*file,IUnknown*requested,IUnknown*thumbnail,void**out){return unsupported_out(f,out);}
static HRESULT WINAPI file_from_uri(Face*f,IUnknown*uri,void**out){return unsupported_out(f,out);}
static HRESULT WINAPI streamed_from_uri(Face*f,HSTRING name,IUnknown*uri,IUnknown*thumbnail,void**out){return unsupported_out(f,out);}
static HRESULT WINAPI streamed_replace_uri(Face*f,IUnknown*file,IUnknown*uri,IUnknown*thumbnail,void**out){return unsupported_out(f,out);}
static const void *file_statics_vt[]={BASE,file_from_path,file_from_uri,streamed_create,streamed_replace,streamed_from_uri,streamed_replace_uri};
static Object *create(int kind){
    Object*o=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*o)),*child;if(!o)return NULL;
    o->main.o=o->other.o=o;o->refs=1;o->kind=kind;
    switch(kind){
    case FACTORY_SAVE:case FACTORY_UWP_OPEN:o->main.vt=factory_save_vt;o->iid=ID_Activation;break;
    case FACTORY_OPEN:o->main.vt=factory_save_vt;o->other.vt=factory_open_vt;o->iid=ID_Activation;break;
    case FACTORY_FILE:o->main.vt=factory_save_vt;o->other.vt=file_statics_vt;o->iid=ID_Activation;break;
    case SAVE:case OPEN:case UWP_OPEN:o->main.vt=kind==SAVE?save_vt:kind==OPEN?open_vt:uwp_open_vt;o->other.vt=window_vt;o->iid=kind==SAVE?ID_Save:kind==OPEN?ID_Open:ID_UwpOpen;child=create(kind==SAVE?MAP:VECTOR);if(!child){HeapFree(GetProcessHeap(),0,o);return NULL;}o->child=(IUnknown*)&child->main;break;
    case VECTOR:o->main.vt=vector_vt;o->other.vt=view_vt;o->iid=ID_Vector;break;
    case MAP:o->main.vt=map_vt;o->iid=ID_Map;break;
    case FILE_RESULT:o->main.vt=file_vt;o->other.vt=item_vt;o->iid=ID_StorageFile;break;
    case ASYNC:o->main.vt=async_vt;o->other.vt=info_vt;o->iid=ID_AsyncFile;break;
    }
    return o;
}
HRESULT WINAPI DllGetActivationFactory(HSTRING name,void**out){
    const WCHAR*s=WindowsGetStringRawBuffer(name,NULL);Object*o;int kind;
    if(!out)return E_POINTER;*out=NULL;
    if(!wcscmp(s,L"Windows.Storage.Pickers.FileSavePicker"))kind=FACTORY_SAVE;
    else if(!wcscmp(s,L"Microsoft.Windows.Storage.Pickers.FileOpenPicker"))kind=FACTORY_OPEN;
    else if(!wcscmp(s,L"Windows.Storage.Pickers.FileOpenPicker"))kind=FACTORY_UWP_OPEN;
    else if(!wcscmp(s,L"Windows.Storage.StorageFile"))kind=FACTORY_FILE;
    else return CLASS_E_CLASSNOTAVAILABLE;
    o=create(kind);if(!o)return E_OUTOFMEMORY;
    *out=&o->main;return S_OK;
}
HRESULT WINAPI DllCanUnloadNow(void){return S_FALSE;}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,void*reserved){if(reason==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(instance);return TRUE;}
#ifdef __WINESRC__
BOOL WINAPI DllMainCRTStartup(HINSTANCE instance,DWORD reason,void*reserved){return DllMain(instance,reason,reserved);}
#endif
