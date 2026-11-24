// C ABI over zsign (github.com/zhlynn/zsign): sign an .ipa with a p12 and a
// provisioning profile. Mirrors the IPA path of zsign's own main().
#include "common.h"
#include "bundle.h"
#include "openssl.h"
#include "archive.h"
#include "util.h"

#include <string>
#include <vector>
#include <unistd.h>

// zsign logs with printf; route it to stderr so stdout stays clean for
// machine-readable output (ferry --json) and the zig test runner protocol.
struct StdoutToStderr {
	int saved;
	StdoutToStderr() { fflush(stdout); saved = dup(1); dup2(2, 1); }
	~StdoutToStderr() { fflush(stdout); if (saved >= 0) { dup2(saved, 1); close(saved); } }
};

extern "C" int ferry_zsign_ipa(
	const char* input,
	const char* output,
	const char* p12,
	const char* password,
	const char* profile,
	const char* bundle_id,     // may be NULL: keep
	const char* display_name,  // may be NULL: keep
	const char* const* dylibs, // may be NULL
	size_t ndylibs,
	const char* tmp_dir,
	int verbose)
{
	StdoutToStderr redirect;
	ZLog::SetLogLever(verbose ? ZLog::E_INFO : ZLog::E_ERROR);

	ZSignAsset zsa;
	if (!zsa.Init("", p12, profile, "", password ? password : "", false, true, false)) {
		return 1;
	}

	string folder = ZFile::GetRealPathV("%s/ferry_sign_%llu", tmp_dir, ZUtil::GetMicroSecond());
	if (!Zip::Extract(input, folder.c_str())) {
		ZFile::RemoveFolder(folder.c_str());
		return 2;
	}

	vector<string> inject;
	for (size_t i = 0; i < ndylibs; i++) inject.push_back(dylibs[i]);
	vector<string> remove;

	ZBundle bundle;
	bool ok = bundle.SignFolder(&zsa, folder,
		bundle_id ? bundle_id : "",
		"",
		display_name ? display_name : "",
		inject, remove,
		true /* force */, false /* weak */, false /* cache */);

	int rc = ok ? 0 : 3;
	if (ok) {
		size_t pos = bundle.m_strAppFolder.rfind("Payload");
		if (pos == string::npos || pos == 0) {
			rc = 4;
		} else {
			string base = bundle.m_strAppFolder.substr(0, pos - 1);
			if (!Zip::Archive(base.c_str(), output, 0)) rc = 5;
		}
	}
	ZFile::RemoveFolder(folder.c_str());
	return rc;
}
