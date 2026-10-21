#import "PCPythonRuntime.h"
#import <NaturalLanguage/NaturalLanguage.h>
#import <os/log.h>
#include <Python/Python.h>

static NSLock *inboxLock;
static NSMutableArray<NSString *> *inbox;
static void (^eventHandler)(NSString *);

static PyObject *native_emit(PyObject *self, PyObject *args) {
    const char *json;
    if (!PyArg_ParseTuple(args, "s", &json)) return NULL;
    NSString *event = [NSString stringWithUTF8String:json];
    dispatch_async(dispatch_get_main_queue(), ^{ if (eventHandler) eventHandler(event); });
    Py_RETURN_NONE;
}

static PyObject *native_poll(PyObject *self, PyObject *args) {
    @autoreleasepool {
        [inboxLock lock];
        NSString *message = inbox.firstObject;
        if (message) [inbox removeObjectAtIndex:0];
        [inboxLock unlock];
        if (!message) Py_RETURN_NONE;
        return PyUnicode_FromString(message.UTF8String);
    }
}

static PyObject *native_log(PyObject *self, PyObject *args) {
    const char *message;
    if (!PyArg_ParseTuple(args, "s", &message)) return NULL;
#if DEBUG
    NSLog(@"Pipecat: %s", message);
#else
    // Pipecat's messages can quote what the user said, so Release logs keep them private.
    os_log_error(OS_LOG_DEFAULT, "Pipecat: %{private}s", message);
#endif
    Py_RETURN_NONE;
}

static PyObject *native_sentence_boundary(PyObject *self, PyObject *args) {
    @autoreleasepool {
        PyObject *value;
        if (!PyArg_ParseTuple(args, "U", &value)) return NULL;
        Py_ssize_t length;
        const char *utf8 = PyUnicode_AsUTF8AndSize(value, &length);
        if (!utf8) return NULL;
        NSString *text = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)length
                                               encoding:NSUTF8StringEncoding];
        if (!text.length) return PyLong_FromLong(0);
        NLTokenizer *tokenizer = [[NLTokenizer alloc] initWithUnit:NLTokenUnitSentence];
        [tokenizer setLanguage:NLLanguageEnglish];
        tokenizer.string = text;
        NSRange range = [tokenizer tokenRangeAtIndex:0];
        if (range.location == NSNotFound) return PyLong_FromLong(0);
        NSUInteger end = NSMaxRange(range);
        if (!end) return PyLong_FromLong(0);
        if (end == text.length) {
            // A single unfinished sentence, including a decimal or abbreviation,
            // needs more lookahead. Closing quotation marks belong to its text.
            NSString *content = [text stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\"'”’)]}"]];
            NSCharacterSet *punctuation = [NSCharacterSet characterSetWithCharactersInString:@".!?;…。？！；．｡।॥؟؛۔"];
            if (!content.length || ![punctuation characterIsMember:[content characterAtIndex:content.length - 1]]) {
                return PyLong_FromLong(0);
            }
        }
        // Foundation ranges use UTF-16. Pipecat slices by Python code points.
        NSData *prefix = [[text substringToIndex:end] dataUsingEncoding:NSUTF8StringEncoding];
        PyObject *decoded = PyUnicode_DecodeUTF8(prefix.bytes, (Py_ssize_t)prefix.length, "strict");
        if (!decoded) return NULL;
        Py_ssize_t boundary = PyUnicode_GetLength(decoded);
        Py_DECREF(decoded);
        return PyLong_FromSsize_t(boundary);
    }
}

static PyMethodDef methods[] = {
    {"emit", native_emit, METH_VARARGS, "Send an event to Swift."},
    {"poll", native_poll, METH_NOARGS, "Receive a native event without blocking."},
    {"log", native_log, METH_VARARGS, "Log an interpreter diagnostic."},
    {"sentence_boundary", native_sentence_boundary, METH_VARARGS, "Find a sentence boundary with Apple's tokenizer."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_pipecat_native", NULL, -1, methods};
PyMODINIT_FUNC PyInit__pipecat_native(void) { return PyModule_Create(&module); }

@implementation PCPythonRuntime
- (void)startWithEventHandler:(void (^)(NSString *))handler {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inboxLock = [NSLock new];
        inbox = [NSMutableArray new];
        eventHandler = [handler copy];
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            @autoreleasepool { [self runInterpreter]; }
        }];
        thread.name = @"Pipecat Python";
        thread.qualityOfService = NSQualityOfServiceUserInitiated;
        [thread start];
    });
}

- (void)sendJSON:(NSString *)json {
    [inboxLock lock];
    [inbox addObject:json];
    [inboxLock unlock];
}

#if DEBUG
- (NSArray<NSString *> *)importedModuleNames {
    if (!Py_IsInitialized()) return @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *modules = PySys_GetObject("modules");
    PyObject *keys = modules ? PyDict_Keys(modules) : NULL;
    for (Py_ssize_t index = 0; keys && index < PyList_Size(keys); index++) {
        const char *name = PyUnicode_AsUTF8(PyList_GetItem(keys, index));
        if (name) [names addObject:@(name)];
    }
    Py_XDECREF(keys);
    PyErr_Clear();
    PyGILState_Release(state);
    return [names sortedArrayUsingSelector:@selector(compare:)];
}
#endif

// Logs what went wrong, and tells the host in words a person can act on.
- (void)reportError:(NSString *)detail {
    NSLog(@"Pipecat runtime: %@", detail);
    NSString *message = @"The conversation engine stopped. Quit and reopen Little Voices to start again.";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"type": @"error", @"message": message}
                                                  options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{ if (eventHandler) eventHandler(json); });
}

- (void)runInterpreter {
    NSString *bundle = NSBundle.mainBundle.resourcePath;
    if (PyImport_AppendInittab("_pipecat_native", PyInit__pipecat_native) < 0) {
        [self reportError:@"Could not register the native Python bridge."];
        return;
    }
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.module_search_paths_set = 1;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home,
                                             [bundle stringByAppendingPathComponent:@"python"].UTF8String);
    if (!PyStatus_Exception(status)) {
        status = PyConfig_SetBytesString(&config, &config.program_name, "PipecatVoice");
    }
    // Pipecat Audience's reference runtime imports as `contracts` and `harness`, as released.
    for (NSString *relative in @[@"python/lib/python3.13", @"python/lib/python3.13/lib-dynload",
                                 @"python-app", @"python-app/pipecat_audience/runtime",
                                 @"python-packages"]) {
        if (PyStatus_Exception(status)) break;
        wchar_t *path = Py_DecodeLocale([bundle stringByAppendingPathComponent:relative].UTF8String, NULL);
        if (!path) { [self reportError:@"Invalid Python resource path."]; PyConfig_Clear(&config); return; }
        status = PyWideStringList_Append(&config.module_search_paths, path);
        PyMem_RawFree(path);
    }
    if (!PyStatus_Exception(status)) status = PyWideStringList_Append(&config.argv, L"PipecatVoice");
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        [self reportError:status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"Python initialization failed."];
        PyConfig_Clear(&config);
        return;
    }
    PyConfig_Clear(&config);
    // This thread owns the interpreter and asyncio loop for the app lifetime.
    int result = PyRun_SimpleString("from mobile_app import run\nrun()\n");
    if (result != 0) [self reportError:@"The Python pipeline stopped; its traceback is above."];
    Py_FinalizeEx();
}
@end
