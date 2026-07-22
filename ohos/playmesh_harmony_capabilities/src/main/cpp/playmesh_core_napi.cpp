#include "napi/native_api.h"
#include "playmesh_core.h"

#include <string>
#include <vector>

namespace {

enum class CoreOperation {
  Start,
  Stop,
};

struct CoreWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  CoreOperation operation = CoreOperation::Start;
  std::string address;
  std::string boundAddress;
  std::string errorMessage;
  int status = 0;
};

std::string ReadString(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return {};
  }
  std::vector<char> buffer(length + 1, '\0');
  size_t written = 0;
  if (napi_get_value_string_utf8(
          env, value, buffer.data(), buffer.size(), &written) != napi_ok) {
    return {};
  }
  return std::string(buffer.data(), written);
}

void ExecuteCoreWork(napi_env, void* data) {
  auto* work = static_cast<CoreWork*>(data);
  char* nativeError = nullptr;
  if (work->operation == CoreOperation::Start) {
    char* nativeAddress = nullptr;
    work->status = PlaymeshCoreStart(
        work->address.c_str(), &nativeAddress, &nativeError);
    if (nativeAddress != nullptr) {
      work->boundAddress = nativeAddress;
      PlaymeshCoreFree(nativeAddress);
    }
  } else {
    work->status = PlaymeshCoreStop(&nativeError);
  }
  if (nativeError != nullptr) {
    work->errorMessage = nativeError;
    PlaymeshCoreFree(nativeError);
  }
}

void CompleteCoreWork(napi_env env, napi_status status, void* data) {
  auto* work = static_cast<CoreWork*>(data);
  if (status == napi_ok && work->status == 0) {
    napi_value result = nullptr;
    if (work->operation == CoreOperation::Start) {
      napi_create_string_utf8(
          env,
          work->boundAddress.c_str(),
          work->boundAddress.size(),
          &result);
    } else {
      napi_get_undefined(env, &result);
    }
    napi_resolve_deferred(env, work->deferred, result);
  } else {
    std::string message = work->errorMessage;
    if (message.empty()) {
      message = status == napi_cancelled
          ? "Playmesh Core operation was cancelled"
          : "Playmesh Core native operation failed";
    }
    napi_value messageValue = nullptr;
    napi_value errorValue = nullptr;
    napi_create_string_utf8(
        env, message.c_str(), message.size(), &messageValue);
    napi_create_error(env, nullptr, messageValue, &errorValue);
    napi_reject_deferred(env, work->deferred, errorValue);
  }
  napi_delete_async_work(env, work->work);
  delete work;
}

napi_value QueueCoreWork(
    napi_env env,
    CoreOperation operation,
    const std::string& address) {
  auto* work = new CoreWork();
  work->operation = operation;
  work->address = address;

  napi_value promise = nullptr;
  napi_create_promise(env, &work->deferred, &promise);

  const char* resourceName = operation == CoreOperation::Start
      ? "PlaymeshCoreStart"
      : "PlaymeshCoreStop";
  napi_value resource = nullptr;
  napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource);
  if (napi_create_async_work(
          env,
          nullptr,
          resource,
          ExecuteCoreWork,
          CompleteCoreWork,
          work,
          &work->work) != napi_ok ||
      napi_queue_async_work(env, work->work) != napi_ok) {
    napi_value message = nullptr;
    napi_value error = nullptr;
    napi_create_string_utf8(
        env,
        "Unable to queue Playmesh Core operation",
        NAPI_AUTO_LENGTH,
        &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, work->deferred, error);
    if (work->work != nullptr) {
      napi_delete_async_work(env, work->work);
    }
    delete work;
  }
  return promise;
}

napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc != 1) {
    napi_throw_type_error(env, nullptr, "start requires one address string");
    return nullptr;
  }
  napi_valuetype valueType = napi_undefined;
  napi_typeof(env, args[0], &valueType);
  if (valueType != napi_string) {
    napi_throw_type_error(env, nullptr, "address must be a string");
    return nullptr;
  }
  std::string address = ReadString(env, args[0]);
  if (address.empty()) {
    address = "0.0.0.0:0";
  }
  return QueueCoreWork(env, CoreOperation::Start, address);
}

napi_value Stop(napi_env env, napi_callback_info) {
  return QueueCoreWork(env, CoreOperation::Stop, {});
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(
      env, exports, sizeof(properties) / sizeof(properties[0]), properties);
  return exports;
}

}  // namespace

static napi_module playmeshCoreModule = {
    1,
    0,
    nullptr,
    Init,
    "playmesh_core_napi",
    nullptr,
    {0},
};

extern "C" __attribute__((constructor)) void RegisterPlaymeshCoreModule() {
  napi_module_register(&playmeshCoreModule);
}
