import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'measurement.dart';
import 'submission_progress.dart';

/// 최근 인증 측정 기록. 표로 복사해 docs/POC_TEST_PLAN.md의 측정표에 붙여넣을 수 있다.
class MeasurementLogCard extends StatelessWidget {
  const MeasurementLogCard({
    super.key,
    required this.measurements,
    required this.onClear,
  });

  final List<Measurement> measurements;
  final VoidCallback onClear;

  static const _visibleCount = 10;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: measurementsToMarkdown(measurements)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('측정 기록 ${measurements.length}건을 표로 복사했습니다.')),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('측정 기록 삭제'),
        content: Text('측정 기록 ${measurements.length}건을 모두 지웁니다. 복사해 두셨나요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) onClear();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final mutedStyle = textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '측정 기록 (${measurements.length})',
                    style: textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  tooltip: '표로 복사',
                  onPressed: measurements.isEmpty ? null : () => _copy(context),
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: '기록 삭제',
                  onPressed: measurements.isEmpty
                      ? null
                      : () => _confirmClear(context),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (measurements.isEmpty)
              Text('인증을 진행하면 소요 시간이 여기에 기록됩니다.', style: mutedStyle)
            else ...[
              for (final m in measurements.take(_visibleCount))
                _MeasurementRow(measurement: m, mutedStyle: mutedStyle),
              if (measurements.length > _visibleCount)
                Text(
                  '외 ${measurements.length - _visibleCount}건은 복사하면 함께 들어갑니다.',
                  style: mutedStyle,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MeasurementRow extends StatelessWidget {
  const _MeasurementRow({required this.measurement, required this.mutedStyle});

  final Measurement measurement;
  final TextStyle? mutedStyle;

  @override
  Widget build(BuildContext context) {
    final m = measurement;
    final result =
        m.finalState?.label ??
        (m.sdkOutcome == SdkOutcome.done
            ? '결과 대기'
            : sdkOutcomeLabel(m.sdkOutcome));
    final local = m.sdkStartedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${m.vendorData} · ${kindLabel(m.kind)} · $result',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}'
            '  ·  촬영·제출 ${formatDuration(m.sdkDuration)}'
            '  ·  접수까지 ${formatDuration(m.toReceipt)}'
            '  ·  심사 ${formatDuration(m.toDecision)}',
            style: mutedStyle,
          ),
        ],
      ),
    );
  }
}
