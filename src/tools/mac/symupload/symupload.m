// Copyright (c) 2006, Google Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// symupload.m: Upload a symbol file to a HTTP server.  The upload is sent as
// a multipart/form-data POST request with the following parameters:
//  code_file: the basename of the module, e.g. "app"
//  debug_file: the basename of the debugging file, e.g. "app"
//  debug_identifier: the debug file's identifier, usually consisting of
//                    the guid and age embedded in the pdb, e.g.
//                    "11111111BBBB3333DDDD555555555555F"
//  os: the operating system that the module was built for
//  cpu: the CPU that the module was built for (x86 or ppc)
//  symbol_file: the contents of the breakpad-format symbol file

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <Foundation/Foundation.h>

#include "HTTPMultipartUpload.h"
#include "HTTPPutRequest.h"
#include "SymbolCollectorClient.h"

typedef enum { kSymUploadProtocolV1, kSymUploadProtocolV2 } SymUploadProtocol;

typedef enum {
  kResultSuccess = 0,
  kResultFailure = 1,
  kResultAlreadyExists = 2
} Result;

typedef struct {
  NSString* symbolsPath;
  NSString* uploadURLStr;
  SymUploadProtocol symUploadProtocol;
  NSString* apiKey;
  BOOL force;
  Result result;
} Options;

//=============================================================================
static NSArray* ModuleDataForSymbolFile(NSString* file) {
  NSFileHandle* fh = [NSFileHandle fileHandleForReadingAtPath:file];
  NSData* data = [fh readDataOfLength:1024];
  NSString* str = [[NSString alloc] initWithData:data
                                        encoding:NSUTF8StringEncoding];
  NSScanner* scanner = [NSScanner scannerWithString:str];
  NSString* line;
  NSMutableArray* parts = nil;
  const int MODULE_ID_INDEX = 3;

  if ([scanner scanUpToString:@"\n" intoString:&line]) {
    parts = [[NSMutableArray alloc] init];
    NSScanner* moduleInfoScanner = [NSScanner scannerWithString:line];
    NSString* moduleInfo;
    // Get everything BEFORE the module name.  None of these properties
    // can have spaces.
    for (int i = 0; i <= MODULE_ID_INDEX; i++) {
      [moduleInfoScanner scanUpToString:@" " intoString:&moduleInfo];
      [parts addObject:moduleInfo];
    }

    // Now get the module name. This can have a space so we scan to
    // the end of the line.
    [moduleInfoScanner scanUpToString:@"\n" intoString:&moduleInfo];
    [parts addObject:moduleInfo];
  }

  [str release];

  return parts;
}

//=============================================================================
static void StartSymUploadProtocolV1(Options* options,
                                     NSArray* moduleParts,
                                     NSString* compactedID) {
  NSURL* url = [NSURL URLWithString:options->uploadURLStr];
  HTTPMultipartUpload* ul = [[HTTPMultipartUpload alloc] initWithURL:url];
  NSMutableDictionary* parameters = [NSMutableDictionary dictionary];

  // Add parameters
  [parameters setObject:compactedID forKey:@"debug_identifier"];

  // MODULE <os> <cpu> <uuid> <module-name>
  // 0      1    2     3      4
  [parameters setObject:[moduleParts objectAtIndex:1] forKey:@"os"];
  [parameters setObject:[moduleParts objectAtIndex:2] forKey:@"cpu"];
  [parameters setObject:[moduleParts objectAtIndex:4] forKey:@"debug_file"];
  [parameters setObject:[moduleParts objectAtIndex:4] forKey:@"code_file"];
  [ul setParameters:parameters];

  NSArray* keys = [parameters allKeys];
  int count = [keys count];
  for (int i = 0; i < count; ++i) {
    NSString* key = [keys objectAtIndex:i];
    NSString* value = [parameters objectForKey:key];
    fprintf(stdout, "'%s' = '%s'\n", [key UTF8String], [value UTF8String]);
  }

  // Add file
  [ul addFileAtPath:options->symbolsPath name:@"symbol_file"];

  // Send it
  NSError* error = nil;
  NSData* data = [ul send:&error];
  NSString* result = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
  int status = [[ul response] statusCode];

  fprintf(stdout, "Send: %s\n",
          error ? [[error description] UTF8String] : "No Error");
  fprintf(stdout, "Response: %d\n", status);
  fprintf(stdout, "Result: %lu bytes\n%s\n", (unsigned long)[data length],
          [result UTF8String]);

  [result release];
  [ul release];
  options->result = (!error && status == 200) ? kResultSuccess : kResultFailure;
}

//=============================================================================
static void StartSymUploadProtocolV2(Options* options,
                                     NSArray* moduleParts,
                                     NSString* debugID) {
  options->result = kResultFailure;

  NSString* debugFile = [moduleParts objectAtIndex:4];
  if (!options->force) {
    SymbolStatus symbolStatus =
        [SymbolCollectorClient checkSymbolStatusOnServer:options->uploadURLStr
                                              withAPIKey:options->apiKey
                                           withDebugFile:debugFile
                                             withDebugID:debugID];
    if (symbolStatus == SymbolStatusFound) {
      fprintf(stdout, "Symbol file already exists, upload aborted."
                      " Use \"-f\" to overwrite.\n");
      options->result = kResultAlreadyExists;
      return;
    } else if (symbolStatus == SymbolStatusUnknown) {
      fprintf(stdout, "Failed to get check for existing symbol.\n");
      return;
    }
  }

  UploadURLResponse* URLResponse =
      [SymbolCollectorClient createUploadURLOnServer:options->uploadURLStr
                                          withAPIKey:options->apiKey];
  if (URLResponse == nil) {
    return;
  }

  NSURL* uploadURL = [NSURL URLWithString:[URLResponse uploadURL]];
  HTTPPutRequest* putRequest = [[HTTPPutRequest alloc] initWithURL:uploadURL];
  [putRequest setFile:options->symbolsPath];

  NSError* error = nil;
  NSData* data = [putRequest send:&error];
  NSString* result = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
  int responseCode = [[putRequest response] statusCode];
  [putRequest release];

  if (error || responseCode != 200) {
    fprintf(stdout, "Failed to upload symbol file.\n");
    fprintf(stdout, "Response code: %d\n", responseCode);
    fprintf(stdout, "Response:\n");
    fprintf(stdout, "%s\n", [result UTF8String]);
    return;
  }

  CompleteUploadResult completeUploadResult =
      [SymbolCollectorClient completeUploadOnServer:options->uploadURLStr
                                         withAPIKey:options->apiKey
                                      withUploadKey:[URLResponse uploadKey]
                                      withDebugFile:debugFile
                                        withDebugID:debugID];
  [URLResponse release];
  if (completeUploadResult == CompleteUploadResultError) {
    fprintf(stdout, "Failed to complete upload.\n");
    return;
  } else if (completeUploadResult == CompleteUploadResultDuplicateData) {
    fprintf(stdout, "Uploaded file checksum matched existing file checksum,"
                    " no change necessary.\n");
  } else {
    fprintf(stdout, "Successfully sent the symbol file.\n");
  }
  options->result = kResultSuccess;
}

//=============================================================================
static void Start(Options* options) {
  NSArray* moduleParts = ModuleDataForSymbolFile(options->symbolsPath);
  NSMutableString* compactedID =
      [NSMutableString stringWithString:[moduleParts objectAtIndex:3]];
  [compactedID replaceOccurrencesOfString:@"-"
                               withString:@""
                                  options:0
                                    range:NSMakeRange(0, [compactedID length])];

  if (options->symUploadProtocol == kSymUploadProtocolV1) {
    StartSymUploadProtocolV1(options, moduleParts, compactedID);
  } else if (options->symUploadProtocol == kSymUploadProtocolV2) {
    StartSymUploadProtocolV2(options, moduleParts, compactedID);
  }
}

//=============================================================================
static void Usage(int argc, const char* argv[]) {
  fprintf(stderr, "Submit symbol information.\n");
  fprintf(stderr, "Usage: %s [options] <symbol-file> <upload-URL>\n", argv[0]);
  fprintf(stderr, "<symbol-file> should be created by using the dump_syms "
                  "tool.\n");
  fprintf(stderr, "<upload-URL> is the destination for the upload.\n");
  fprintf(stderr, "Options:\n");
  fprintf(stderr, "\t-p <protocol>: protocol to use for upload, accepts "
                  "[\"sym-upload-v1\", \"sym-upload-v2\"]. Default is "
                  "\"sym-upload-v1\".\n");
  fprintf(stderr, "\t-k <api-key>: secret for authentication with upload "
                  "server. [Only in sym-upload-v2 protocol mode]\n");
  fprintf(stderr, "\t-f: Overwrite symbol file on server if already present. "
                  "[Only in sym-upload-v2 protocol mode]\n");
  fprintf(stderr, "\t-h: Usage\n");
  fprintf(stderr, "\t-?: Usage\n");
  fprintf(stderr, "Exit codes:\n");
  fprintf(stderr, "\t%d: Success\n", kResultSuccess);
  fprintf(stderr, "\t%d: Failure\n", kResultFailure);
  fprintf(stderr,
          "\t%d: Symbol file already exists on server (and -f was not "
          "specified)\n",
          kResultAlreadyExists);
}

//=============================================================================
static void SetupOptions(int argc, const char* argv[], Options* options) {
  // Set default value of symUploadProtocol.
  options->symUploadProtocol = kSymUploadProtocolV1;

  extern int optind;
  char ch;

  while ((ch = getopt(argc, (char* const*)argv, "p:k:hf?")) != -1) {
    switch (ch) {
      case 'p':
        if (strcmp(optarg, "sym-upload-v2") == 0) {
          options->symUploadProtocol = kSymUploadProtocolV2;
          break;
        } else if (strcmp(optarg, "sym-upload-v1") == 0) {
          // This is already the default but leave in case that changes.
          options->symUploadProtocol = kSymUploadProtocolV1;
          break;
        }
        Usage(argc, argv);
        exit(0);
        break;
      case 'k':
        options->apiKey = [NSString stringWithCString:optarg
                                             encoding:NSASCIIStringEncoding];
        break;
      case 'f':
        options->force = YES;
        break;
      default:
        Usage(argc, argv);
        exit(0);
        break;
    }
  }

  if ((argc - optind) != 2) {
    fprintf(stderr, "%s: Missing symbols file and/or upload-URL\n", argv[0]);
    Usage(argc, argv);
    exit(1);
  }

  int fd = open(argv[optind], O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "%s: %s: %s\n", argv[0], argv[optind], strerror(errno));
    exit(1);
  }

  struct stat statbuf;
  if (fstat(fd, &statbuf) < 0) {
    fprintf(stderr, "%s: %s: %s\n", argv[0], argv[optind], strerror(errno));
    close(fd);
    exit(1);
  }
  close(fd);

  if (!S_ISREG(statbuf.st_mode)) {
    fprintf(stderr, "%s: %s: not a regular file\n", argv[0], argv[optind]);
    exit(1);
  }

  options->symbolsPath = [NSString stringWithUTF8String:argv[optind]];
  options->uploadURLStr = [NSString stringWithUTF8String:argv[optind + 1]];
}

//=============================================================================
int main(int argc, const char* argv[]) {
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  Options options;

  bzero(&options, sizeof(Options));
  SetupOptions(argc, argv, &options);
  Start(&options);

  [pool release];
  return options.result;
}
