import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tracking_state.dart';
import '../models/tracking_status.dart';
import '../providers/tracking_provider.dart';

/// Display current tracking status with visual feedback.
class TrackingStatusIndicator extends ConsumerWidget {
  /// Optional compact mode for use in cards.
  final bool compact;

  /// Whether to show point count.
  final bool showPointCount;

  const TrackingStatusIndicator({
    super.key,
    this.compact = false,
    this.showPointCount = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackingState = ref.watch(trackingProvider);
    final status = trackingState.status;

    final statusConfig = _getStatusConfig(status);

    if (compact) {
      return _buildCompact(context, trackingState, statusConfig);
    }

    return _buildFull(context, ref, trackingState, statusConfig);
  }

  Widget _buildCompact(
    BuildContext context,
    TrackingState trackingState,
    _StatusConfig config,
  ) {
    return Tooltip(
      message: config.label,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: config.color.withAlpha(51),
          shape: BoxShape.circle,
        ),
        child: config.isAnimated
            ? _AnimatedIcon(icon: config.icon, color: config.color)
            : Icon(
                config.icon,
                size: 16,
                color: config.color,
              ),
      ),
    );
  }

  Widget _buildFull(
    BuildContext context,
    WidgetRef ref,
    TrackingState trackingState,
    _StatusConfig config,
  ) {
    final theme = Theme.of(context);
    final pointsCaptured = trackingState.pointsCaptured;
    final isStationary = trackingState.isStationary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: config.color.withAlpha(26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: config.color.withAlpha(77),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          config.isAnimated
              ? _AnimatedIcon(icon: config.icon, color: config.color, size: 20)
              : Icon(
                  config.icon,
                  size: 20,
                  color: config.color,
                ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                config.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: config.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (showPointCount && trackingState.status.isActive) ...[
                Text(
                  '$pointsCaptured points${isStationary ? ' (stationary)' : ''}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: config.color.withAlpha(179),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  _StatusConfig _getStatusConfig(TrackingStatus status) {
    return switch (status) {
      TrackingStatus.stopped => const _StatusConfig(
          icon: Icons.location_off,
          color: Colors.grey,
          label: 'Not Tracking',
          isAnimated: false,
        ),
      TrackingStatus.starting => const _StatusConfig(
          icon: Icons.location_searching,
          color: Colors.orange,
          label: 'Starting...',
          isAnimated: true,
        ),
      TrackingStatus.running => const _StatusConfig(
          icon: Icons.location_on,
          color: Colors.green,
          label: 'Tracking Active',
          isAnimated: true,
        ),
      TrackingStatus.paused => const _StatusConfig(
          icon: Icons.location_disabled,
          color: Colors.orange,
          label: 'GPS Unavailable',
          isAnimated: false,
        ),
      TrackingStatus.error => const _StatusConfig(
          icon: Icons.error,
          color: Colors.red,
          label: 'Tracking Error',
          isAnimated: false,
        ),
    };
  }
}

class _StatusConfig {
  final IconData icon;
  final Color color;
  final String label;
  final bool isAnimated;

  const _StatusConfig({
    required this.icon,
    required this.color,
    required this.label,
    required this.isAnimated,
  });
}

class _AnimatedIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _AnimatedIcon({
    required this.icon,
    required this.color,
    this.size = 16,
  });

  @override
  State<_AnimatedIcon> createState() => _AnimatedIconState();
}

class _AnimatedIconState extends State<_AnimatedIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.5 + (_controller.value * 0.5),
          child: Icon(
            widget.icon,
            size: widget.size,
            color: widget.color,
          ),
        );
      },
    );
  }
}
