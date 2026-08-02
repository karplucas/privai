/// Which subsystem a downloadable model belongs to.
enum ModelKind {
  llm,
  tts,
  stt;

  static ModelKind? fromKey(String key) {
    for (final kind in ModelKind.values) {
      if (kind.name == key) return kind;
    }
    return null;
  }

  String get label => switch (this) {
        ModelKind.llm => 'Language models',
        ModelKind.tts => 'Text-to-speech models',
        ModelKind.stt => 'Speech-to-text models',
      };
}

/// One file belonging to a model.
///
/// ONNX graphs whose weights exceed the protobuf limit keep them in a sidecar
/// named inside the graph (`foo.onnx` + `foo.onnx_data`). ONNX Runtime resolves
/// that name relative to the graph, so [name] must be preserved exactly and the
/// pair must land in the same directory.
class ModelFile {
  const ModelFile({
    required this.pathInRepo,
    required this.name,
    this.repo,
    this.revision,
  });

  /// Path within the source repository.
  final String pathInRepo;

  /// Filename on disk. Defaults to the repo path's basename.
  final String name;

  /// Optional source override for bundles assembled from compatible exports.
  final String? repo;

  /// Revision in [repo], or the parent model revision when omitted.
  final String? revision;

  factory ModelFile.fromJson(Object? json) {
    if (json is String) {
      return ModelFile(pathInRepo: json, name: json.split('/').last);
    }
    if (json is Map<String, dynamic>) {
      final path = json['file'] as String?;
      if (path == null || path.isEmpty) {
        throw FormatException('Model file entry is missing "file": $json');
      }
      return ModelFile(
        pathInRepo: path,
        name: json['as'] as String? ?? path.split('/').last,
        repo: json['repo'] as String?,
        revision: json['revision'] as String?,
      );
    }
    throw FormatException('Unrecognised model file entry: $json');
  }
}

/// A single downloadable model, as declared in `assets/models_list.json`.
///
/// Download URLs and license pages are derived from [repo] and [repoFile] so
/// that the two can never drift apart — a gated model's "accept the license"
/// page must point at the same repository the bytes come from.
class ModelSpec {
  const ModelSpec({
    required this.kind,
    required this.name,
    required this.repo,
    required this.repoFile,
    required this.filename,
    required this.size,
    required this.description,
    required this.gated,
    this.revision = 'main',
    this.license,
    this.licenseNote,
    this.urlOverride,
    this.homepage,
    this.engine,
    List<ModelFile>? files,
    this.bundleDirectory,
  }) : _files = files;

  final ModelKind kind;
  final String name;

  /// Hugging Face repository id, e.g. `google/gemma-3n-E2B-it-litert-preview`.
  final String repo;

  /// Path of the weights file inside [repo].
  final String repoFile;

  /// Name the file is given on the device.
  final String filename;

  /// Human-readable download size, e.g. `1.6GB`.
  final String size;

  final String description;

  /// Whether the repository requires accepting a license before download.
  ///
  /// For the Gemma models this is Google's Gemma Terms of Use, which Hugging
  /// Face presents on the model page and which must be acknowledged with the
  /// signed-in account before any download will be authorised.
  final bool gated;

  final String revision;

  /// Name of the license that has to be accepted, e.g. `Gemma Terms of Use`.
  final String? license;

  /// Extra guidance shown to the user before they are sent to the model page.
  final String? licenseNote;

  /// Escape hatch for files that are not hosted on Hugging Face, or that do not
  /// follow the standard resolve URL layout.
  final String? urlOverride;

  /// Where the model is documented, when that is not a Hugging Face repo page.
  final String? homepage;

  /// Which engine consumes this model, when a kind supports more than one
  /// (currently only text-to-speech does).
  final String? engine;

  /// Subdirectory holding the files of a multi-file model, keeping its sidecars
  /// beside their graphs and away from other models.
  final String? bundleDirectory;

  final List<ModelFile>? _files;

  /// Every file that has to be present for the model to be usable.
  ///
  /// Single-file entries yield exactly one, so callers can treat both uniformly.
  List<ModelFile> get files =>
      _files ?? [ModelFile(pathInRepo: repoFile, name: filename)];

  /// Every file that has to be on disk before the model can be used.
  List<String> get requiredFilenames => files.map((f) => f.name).toList();

  /// Whether this model's files live together in [bundleDirectory].
  ///
  /// An explicit directory is enough on its own.
  bool get isBundle => bundleDirectory != null || (_files?.length ?? 0) > 1;

  /// Download URL for [file].
  Uri urlFor(ModelFile file) {
    if (urlOverride != null && !isBundle) return Uri.parse(urlOverride!);
    final sourceRepo = file.repo ?? repo;
    final sourceRevision = file.revision ?? revision;
    return Uri.parse(
      'https://huggingface.co/$sourceRepo/resolve/$sourceRevision/${file.pathInRepo}',
    );
  }

  /// Page presenting the license and, for gated repositories, the accept
  /// button.
  Uri get licensePageUrl =>
      Uri.parse(homepage ?? 'https://huggingface.co/$repo');

  /// A URL that stands for this model as a whole.
  ///
  /// For a bundle this is its first file, not [filename] — that names the
  /// directory the files are stored in and is not a path in the repository.
  /// Probing it returned `EntryNotFound`, which surfaced to the user as a bare
  /// "Entry not found" when the access check ran before the download.
  Uri get downloadUrl {
    if (isBundle) return urlFor(files.first);
    return Uri.parse(
      urlOverride ?? 'https://huggingface.co/$repo/resolve/$revision/$repoFile',
    );
  }

  factory ModelSpec.fromJson(ModelKind kind, Map<String, dynamic> json) {
    final repo = json['repo'] as String?;
    final filename = json['filename'] as String?;
    if (repo == null || repo.isEmpty) {
      throw FormatException('Model entry is missing "repo": $json');
    }
    if (filename == null || filename.isEmpty) {
      throw FormatException('Model entry is missing "filename": $json');
    }

    return ModelSpec(
      kind: kind,
      name: json['name'] as String? ?? filename,
      repo: repo,
      repoFile: json['file'] as String? ?? filename,
      filename: filename,
      size: json['size'] as String? ?? 'unknown size',
      description: json['description'] as String? ?? '',
      gated: json['gated'] as bool? ?? false,
      revision: json['revision'] as String? ?? 'main',
      license: json['license'] as String?,
      licenseNote: json['licenseNote'] as String?,
      urlOverride: json['url'] as String?,
      homepage: json['homepage'] as String?,
      engine: json['engine'] as String?,
      bundleDirectory: json['directory'] as String?,
      files: (json['files'] as List?)?.map(ModelFile.fromJson).toList(),
    );
  }

  @override
  String toString() => 'ModelSpec($repo/$repoFile -> $filename)';
}

/// A language entry from the TTS/STT language lists.
class LanguageOption {
  const LanguageOption({required this.code, required this.name});

  final String code;
  final String name;

  factory LanguageOption.fromJson(Map<String, dynamic> json) {
    final code = json['code'] as String;
    return LanguageOption(
      code: code,
      name: json['name'] as String? ?? code.toUpperCase(),
    );
  }
}
