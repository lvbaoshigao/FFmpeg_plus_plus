import '../models/models.dart';

/// The visual state for a task's progress surface.
enum TaskProgressMode { hidden, indeterminate, determinate, paused }

/// Centralizes the distinction between a real progress signal and a default
/// zero-filled TaskInfo. Image operations often have no frame timeline, so
/// their initial 0% must not be presented as a measured percentage.
class TaskProgressDisplay {
  const TaskProgressDisplay._();

  /// Selects the progress surface for [task].
  ///
  /// Processing tasks stay indeterminate until a current progress value
  /// reaches the immutable task snapshot. Paused tasks retain a static
  /// surface, while completed tasks are determinate at 100% even when the
  /// executor never emitted a heartbeat.
  static TaskProgressMode modeFor(TaskInfo task) {
    switch (task.status) {
      case TaskStatus.pending:
        return TaskProgressMode.hidden;
      case TaskStatus.processing:
        return hasProgressSignal(task)
            ? TaskProgressMode.determinate
            : TaskProgressMode.indeterminate;
      case TaskStatus.paused:
        return TaskProgressMode.paused;
      case TaskStatus.completed:
        return TaskProgressMode.determinate;
      case TaskStatus.failed:
      case TaskStatus.cancelled:
        return hasProgressSignal(task)
            ? TaskProgressMode.determinate
            : TaskProgressMode.hidden;
    }
  }

  /// Whether the task contains a current, computable progress value.
  ///
  /// A non-empty call-progress list alone is not evidence: pipeline setup
  /// initializes it with zeroes before the first step starts. For pipelines,
  /// only the current step is considered; a completed previous step must not
  /// turn a new step's synthetic overall fraction into a false percentage.
  /// Telemetry such as speed or frame is intentionally ignored because the
  /// immutable task model does not retain the stream's total time and those
  /// values can survive a pipeline step transition.
  static bool hasProgressSignal(TaskInfo task) {
    if (task.pipelineCalls != null && task.pipelineCalls!.isNotEmpty) {
      final index = task.currentCallIndex;
      if (index < 0 || index >= task.callProgresses.length) return false;
      final value = task.callProgresses[index];
      return value.isFinite && value > 0 && value < 1;
    }
    return task.progress.isFinite && task.progress > 0;
  }

  /// Whether this task should render a determinate bar rather than a loader.
  /// Paused tasks use the same frozen bar when they have a measured value.
  static bool showsDeterminate(TaskInfo task) {
    if (task.status == TaskStatus.completed) return true;
    if (task.status != TaskStatus.processing &&
        task.status != TaskStatus.paused &&
        task.status != TaskStatus.failed &&
        task.status != TaskStatus.cancelled) {
      return false;
    }
    return hasProgressSignal(task);
  }

  /// Whether the solid polygon loader should be shown.
  static bool showsLoader(TaskInfo task) =>
      (task.status == TaskStatus.processing ||
          task.status == TaskStatus.paused) &&
      !showsDeterminate(task);

  /// Processing-only animation flag for PolygonMorphLoader.reduceMotion.
  static bool animatesLoader(TaskInfo task) =>
      task.status == TaskStatus.processing && showsLoader(task);

  /// Remaining time is useful only when the backend supplied a real value.
  static bool showsRemaining(TaskInfo task) {
    if (task.status != TaskStatus.processing &&
        task.status != TaskStatus.paused) {
      return false;
    }
    if (!showsDeterminate(task)) return false;
    final remaining = task.remaining.trim().toLowerCase();
    return remaining.isNotEmpty &&
        remaining != 'n/a' &&
        remaining != 'na' &&
        remaining != 'unknown' &&
        remaining != '-' &&
        remaining != '--';
  }

  /// A percentage is honest for completed tasks or after a real signal.
  static bool showsPercentage(TaskInfo task) {
    if (task.status == TaskStatus.completed) return true;
    if (task.status == TaskStatus.pending) return false;
    return hasProgressSignal(task);
  }

  /// The current step's fraction for the lower progress bar.
  ///
  /// If an overall signal exists for a non-pipeline task, use its percentage.
  /// For a pipeline, the current step value is returned directly so previous
  /// step completion cannot be mistaken for current-step progress.
  static double? currentStepValue(TaskInfo task) {
    if (!showsDeterminate(task)) return null;
    if (task.status == TaskStatus.completed) return 1.0;

    if (task.pipelineCalls != null && task.pipelineCalls!.isNotEmpty) {
      final index = task.currentCallIndex;
      if (index < 0 || index >= task.callProgresses.length) return 0.0;
      final value = task.callProgresses[index];
      return value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    }
    if (!task.progress.isFinite) return 0.0;
    return (task.progress / 100).clamp(0.0, 1.0);
  }

  /// Overall task percentage, normalized for text and progress widgets.
  /// Pipeline progress is derived from every stage so the display remains
  /// correct even when the runner stores only the current stage percentage.
  static double overallValue(TaskInfo task) {
    if (task.status == TaskStatus.completed) return 1.0;
    final calls = task.pipelineCalls;
    if (calls != null && calls.isNotEmpty) {
      if (task.callProgresses.isEmpty) return 0.0;
      var total = 0.0;
      for (final value in task.callProgresses) {
        if (value.isFinite) total += value.clamp(0.0, 1.0);
      }
      // The runner expands loops and excludes cleanup calls before creating
      // this list, so its length is the actual executed stage count.
      return (total / task.callProgresses.length).clamp(0.0, 1.0);
    }
    if (!task.progress.isFinite) return 0.0;
    return (task.progress / 100).clamp(0.0, 1.0);
  }
}
