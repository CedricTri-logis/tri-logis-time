import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/colleague_status.dart';
import '../providers/colleagues_provider.dart';

class ColleaguesScreen extends ConsumerWidget {
  const ColleaguesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(colleaguesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Collègues'),
      ),
      body: state.isLoading && state.colleagues.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : state.error != null && state.colleagues.isEmpty
              ? _ErrorView(
                  message: state.error!,
                  onRetry: () =>
                      ref.read(colleaguesProvider.notifier).refresh(),
                )
              : RefreshIndicator(
                  onRefresh: () =>
                      ref.read(colleaguesProvider.notifier).refresh(),
                  child: state.colleagues.isEmpty
                      ? const _EmptyView()
                      : CustomScrollView(
                          slivers: [
                            SliverToBoxAdapter(
                              child: _SummaryBar(state: state),
                            ),
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) => _ColleagueTile(
                                  colleague: state.colleagues[index],
                                ),
                                childCount: state.colleagues.length,
                              ),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 24),
                            ),
                          ],
                        ),
                ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final ColleaguesState state;
  const _SummaryBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        '${state.onShiftCount} en quart · '
        '${state.onLunchCount} en dîner · '
        '${state.offShiftCount} hors quart',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
      ),
    );
  }
}

class _ColleagueTile extends StatelessWidget {
  final ColleagueStatus colleague;
  const _ColleagueTile({required this.colleague});

  @override
  Widget build(BuildContext context) {
    final (badgeColor, badgeTextColor) = switch (colleague.workStatus) {
      WorkStatus.onShift => (Colors.green[100]!, Colors.green[800]!),
      WorkStatus.onLunch => (Colors.orange[100]!, Colors.orange[800]!),
      WorkStatus.offShift => (Colors.grey[200]!, Colors.grey[600]!),
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colleague.workStatus == WorkStatus.offShift
            ? Colors.grey[300]
            : Colors.blue[100],
        child: Text(
          colleague.initials,
          style: TextStyle(
            color: colleague.workStatus == WorkStatus.offShift
                ? Colors.grey[600]
                : Colors.blue[800],
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      title: Text(colleague.fullName),
      subtitle: colleague.sessionLabel != null
          ? Text(
              colleague.sessionLabel!,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            )
          : null,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: badgeColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          colleague.statusLabel,
          style: TextStyle(
            color: badgeTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.people_outline, size: 64, color: Colors.grey[300]),
        const SizedBox(height: 16),
        Text(
          'Aucun collègue trouvé',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[500], fontSize: 16),
        ),
      ],
    );
  }
}
