#ifndef RUNNER_SPEECH_RECOGNITION_HOST_H_
#define RUNNER_SPEECH_RECOGNITION_HOST_H_

#include <string>

namespace playmesh::speech_recognition {

inline constexpr char kChannelName[] = "playmesh/speech_recognition";
inline constexpr char kDiagnoseInitializationFailureMethod[] =
    "diagnoseInitializationFailure";

struct Diagnosis {
  bool available = false;
  std::string code;
  std::string message;
  std::string stage;
  std::string diagnostic;
};

Diagnosis DiagnoseInitializationFailure();

}  // namespace playmesh::speech_recognition

#endif  // RUNNER_SPEECH_RECOGNITION_HOST_H_
