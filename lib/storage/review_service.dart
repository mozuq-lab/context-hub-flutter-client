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
    List<ReviewCandidate> covers = const [],
  }) async {
    return CaptureService(access, location).saveReview(
      operationId,
      candidate,
      action,
      target: target,
      covers: covers,
    );
  }

  Future<CaptureResult> keep(String operationId, ReviewCandidate candidate) =>
      CaptureService(access, location).savePolicyKeep(operationId, candidate);

  Future<CaptureResult> retire(String operationId, ReviewCandidate candidate) =>
      CaptureService(access, location).saveRetirement(operationId, candidate);
}
