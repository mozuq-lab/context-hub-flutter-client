import '../core/review_candidates.dart';
import 'capture_service.dart';
import 'vault_access.dart';

class ReviewService {
  ReviewService(this.access, this.location);
  final VaultAccess access;
  final VaultLocation location;
  Future<CaptureResult> submit(
    String operationId,
    ReviewCandidate candidate,
    String action, {
    AdoptionTarget? target,
  }) async {
    return CaptureService(
      access,
      location,
    ).saveReview(operationId, candidate, action, target: target);
  }

  Future<CaptureResult> retire(String operationId, ReviewCandidate candidate) =>
      CaptureService(access, location).saveRetirement(operationId, candidate);
}
