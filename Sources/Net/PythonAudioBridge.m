#import "PythonAudioBridge.h"
#import <dispatch/dispatch.h>
#import <Python/Python.h>

static BOOL appendModulePath(NSString *path) {
    PyObject *value = PyUnicode_DecodeFSDefault(path.fileSystemRepresentation);
    if (!value) { return NO; }
    int result = PyList_Append(PySys_GetObject("path"), value);
    Py_DECREF(value);
    return result == 0;
}

static PyObject *requestFunction(void) {
    static PyObject *function;
    static dispatch_once_t initialized;
    dispatch_once(&initialized, ^{
        NSString *resources = NSBundle.mainBundle.resourcePath;
        NSString *home = [resources stringByAppendingPathComponent:@"python"];
        NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.13/encodings/__init__.py"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:stdlib]) { return; }

        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        if (PyStatus_Exception(Py_PreInitialize(&preconfig))) { return; }

        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.install_signal_handlers = 0;
        config.write_bytecode = 0;
        PyStatus status = PyConfig_SetBytesString(&config, &config.home, home.fileSystemRepresentation);
        if (!PyStatus_Exception(status)) { status = Py_InitializeFromConfig(&config); }
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) { return; }

        if (appendModulePath([resources stringByAppendingPathComponent:@"Resolver"])
            && appendModulePath([resources stringByAppendingPathComponent:@"app_packages"])) {
            PyObject *module = PyImport_ImportModule("hk_audio_resolver");
            if (module) {
                function = PyObject_GetAttrString(module, "request");
                Py_DECREF(module);
                if (function && !PyCallable_Check(function)) { Py_CLEAR(function); }
            }
        }
        PyErr_Clear();
        PyEval_SaveThread();
    });
    return function;
}

NSString *HKPythonAudioRequest(NSString *request) {
    PyObject *function = requestFunction();
    if (!function) { return nil; }

    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *argument = PyUnicode_FromString(request.UTF8String);
    PyObject *response = argument ? PyObject_CallOneArg(function, argument) : NULL;
    const char *text = response ? PyUnicode_AsUTF8(response) : NULL;
    NSString *result = text ? [NSString stringWithUTF8String:text] : nil;
    Py_XDECREF(response);
    Py_XDECREF(argument);
    PyErr_Clear();
    PyGILState_Release(state);
    return result;
}
