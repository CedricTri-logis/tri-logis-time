import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/team_dashboard_state.dart';

/// Bar chart widget displaying hours worked by each team member.
///
/// Uses fl_chart package for chart rendering.
/// Shows horizontal bar chart with employee names on Y-axis and hours on X-axis.
class TeamHoursChart extends StatelessWidget {
  final List<EmployeeHoursData> data;

  /// Optional height for the chart.
  final double? height;

  /// Whether to show employee names on the Y-axis.
  final bool showNames;

  /// Maximum hours to display (for axis scaling).
  final double? maxHours;

  const TeamHoursChart({
    super.key,
    required this.data,
    this.height,
    this.showNames = true,
    this.maxHours,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const _EmptyChart();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Calculate chart height based on data count
    final chartHeight = height ?? (data.length * 50.0).clamp(150.0, 400.0);

    // Find max value for axis scaling
    final calculatedMax = data.map((e) => e.totalHours).reduce((a, b) => a > b ? a : b);
    final displayMax = maxHours ?? (calculatedMax == 0 ? 10 : calculatedMax * 1.2);

    return SizedBox(
      height: chartHeight,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: displayMax,
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (group) => colorScheme.inverseSurface,
              tooltipPadding: const EdgeInsets.all(8),
              tooltipMargin: 8,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final employee = data[groupIndex];
                return BarTooltipItem(
                  '${employee.displayName}\n',
                  TextStyle(
                    color: colorScheme.onInverseSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  children: [
                    TextSpan(
                      text: employee.formattedHours,
                      style: TextStyle(
                        color: colorScheme.onInverseSurface,
                        fontWeight: FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${value.toInt()}h',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
                reservedSize: 30,
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: showNames,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= data.length) {
                    return const SizedBox.shrink();
                  }
                  final employee = data[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      _truncateName(employee.displayName),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
                reservedSize: showNames ? 80 : 0,
              ),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            show: true,
            drawHorizontalLine: false,
            drawVerticalLine: true,
            verticalInterval: displayMax > 40 ? 10 : 5,
            getDrawingVerticalLine: (value) => FlLine(
              color: colorScheme.outlineVariant.withOpacity(0.3),
              strokeWidth: 1,
            ),
          ),
          barGroups: _createBarGroups(colorScheme),
        ),
      ),
    );
  }

  List<BarChartGroupData> _createBarGroups(ColorScheme colorScheme) {
    return data.asMap().entries.map((entry) {
      final index = entry.key;
      final employee = entry.value;

      return BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: employee.totalHours,
            color: _getBarColor(index, colorScheme),
            width: 20,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(4),
            ),
          ),
        ],
      );
    }).toList();
  }

  Color _getBarColor(int index, ColorScheme colorScheme) {
    final colors = [
      colorScheme.primary,
      colorScheme.secondary,
      colorScheme.tertiary,
      Colors.teal,
      Colors.orange,
      Colors.purple,
    ];
    return colors[index % colors.length];
  }

  String _truncateName(String name) {
    if (name.length <= 12) return name;
    return '${name.substring(0, 10)}...';
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bar_chart,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 8),
            Text(
              'No data for this period',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal bar chart variant for wide screens.
class TeamHoursHorizontalChart extends StatelessWidget {
  final List<EmployeeHoursData> data;
  final double? width;

  const TeamHoursHorizontalChart({
    super.key,
    required this.data,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const _EmptyChart();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final chartHeight = (data.length * 40.0).clamp(100.0, 300.0);
    final maxValue = data.map((e) => e.totalHours).reduce((a, b) => a > b ? a : b);
    final double displayMax = maxValue == 0 ? 10.0 : maxValue * 1.2;

    return SizedBox(
      height: chartHeight,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceEvenly,
          maxY: displayMax,
          rotationQuarterTurns: 1,
          titlesData: FlTitlesData(
            show: true,
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= data.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      data[index].displayName,
                      style: theme.textTheme.labelSmall,
                    ),
                  );
                },
                reservedSize: 100,
              ),
            ),
            bottomTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) => Text(
                  '${value.toInt()}h',
                  style: theme.textTheme.labelSmall,
                ),
                reservedSize: 40,
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
          barGroups: data.asMap().entries.map((entry) {
            return BarChartGroupData(
              x: entry.key,
              barRods: [
                BarChartRodData(
                  toY: entry.value.totalHours,
                  color: colorScheme.primary,
                  width: 16,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}
