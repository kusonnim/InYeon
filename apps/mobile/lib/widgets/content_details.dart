import 'package:flutter/material.dart';

import '../models/content.dart';

class ContentDetails extends StatelessWidget {
  const ContentDetails(
      {super.key, required this.content, required this.footer});

  final ContentItem content;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(content.title ?? 'Untitled content',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          const Text('Original source',
              style: TextStyle(fontWeight: FontWeight.bold)),
          if (content.sourceUrl != null) SelectableText(content.sourceUrl!),
          if (content.sourceText != null) Text(content.sourceText!),
          if (content.assetIds.isNotEmpty)
            const Text('Private attachment saved.'),
          const SizedBox(height: 16),
          const Text('AI interpretation',
              style: TextStyle(fontWeight: FontWeight.bold)),
          Text(content.analysis?.summary ??
              switch (content.analysisStatus) {
                AnalysisStatus.pending => 'Analysis pending.',
                AnalysisStatus.processing => 'Analysis in progress.',
                AnalysisStatus.failed => 'Analysis could not finish.',
                _ => 'No grounded summary is available.',
              }),
          Text(
              'Coverage: ${content.analysis?.coverage.name ?? 'Not analyzed'}'),
          ...?content.analysis?.limitations.map(Text.new),
          const SizedBox(height: 16),
          const Text('Recommendations',
              style: TextStyle(fontWeight: FontWeight.bold)),
          if (content.recommendations.isEmpty)
            const Text('No recommendation is appropriate for this content.'),
          ...content.recommendations.map((item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${item.kind.name}: ${item.text}'),
                      if (item.userText != null)
                        Text('User edit: ${item.userText}'),
                      Text(item.accepted
                          ? 'Explicitly accepted'
                          : 'Generated suggestion awaiting acceptance'),
                    ]),
              )),
          const SizedBox(height: 16),
          const Text('Your notes',
              style: TextStyle(fontWeight: FontWeight.bold)),
          Text(content.userNote ?? 'No notes yet.'),
          const SizedBox(height: 16),
          Text('Workflow: ${content.workflowStatus.name}'),
          ...footer,
        ],
      );
}
