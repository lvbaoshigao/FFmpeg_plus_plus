import 'package:ffmpegpp_gui/widgets/app_slider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Comet trail samples', () {
    test(
      'should put the bright tip after the dim emitter in chronological order',
      () {
        final ages = CometTrailTestProbe.sampleAges(samples: 4, life: 0.75);

        expect(ages.first, 1);
        expect(ages.last, 0.25);
        expect(ages[0], greaterThan(ages[1]));
        expect(ages[1], greaterThan(ages[2]));
        expect(ages[2], greaterThan(ages[3]));
      },
    );

    test('should retain elapsed sample remainder', () {
      expect(
        CometTrailTestProbe.sampledElapsed(0.1, 1 / 45),
        closeTo(0.011111, 0.00001),
      );
    });

    test('should intensify only after drag speed rises', () {
      expect(CometTrailTestProbe.speedEnvelope(0), 0);
      expect(CometTrailTestProbe.speedEnvelope(450), closeTo(0.5, 1e-12));
      expect(CometTrailTestProbe.speedEnvelope(900), 1);
      expect(CometTrailTestProbe.speedEnvelope(1800), 1);
    });

    test('should keep emitter-only first sample dim', () {
      expect(
        CometTrailTestProbe.sampleAges(samples: 1, life: 0.8).single,
        closeTo(0.2, 1e-12),
      );
    });
  });
}
