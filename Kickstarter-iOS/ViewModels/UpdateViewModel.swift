import Argo
import KsApi
import Library
import Prelude
import ReactiveCocoa
import Result

internal protocol UpdateViewModelInputs {
  /// Call with the project and update given to the controller.
  func configureWith(project project: Project, update: Update)

  /// Call when the webview needs to decide a policy for a navigation action. Returns the decision policy.
  func decidePolicyFor(navigationAction navigationAction: WKNavigationActionProtocol)
    -> WKNavigationActionPolicy

  /// Call when the view loads.
  func viewDidLoad()
}

internal protocol UpdateViewModelOutputs {
  /// Emits when we should go to comments for the update.
  var goToComments: Signal<Update, NoError> { get }

  /// Emits when we should go to the project.
  var goToProject: Signal<(Project, RefTag?), NoError> { get }

  /// Emits the title of the controller.
  var title: Signal<String, NoError> { get }

  /// Emits a request that should be loaded into the webview.
  var webViewLoadRequest: Signal<NSURLRequest, NoError> { get }
}

internal protocol UpdateViewModelType {
  var inputs: UpdateViewModelInputs { get }
  var outputs: UpdateViewModelOutputs { get }
}

internal final class UpdateViewModel: UpdateViewModelType, UpdateViewModelInputs, UpdateViewModelOutputs {

  // swiftlint:disable function_body_length
  internal init() {
    let initialUpdate = self.updateProperty.signal.ignoreNil()

    let initialUpdateLoadRequest = initialUpdate
      .takeWhen(self.viewDidLoadProperty.signal)
      .map { NSURL(string: $0.urls.web.update) }
      .ignoreNil()
      .map { AppEnvironment.current.apiService.preparedRequest(forURL: $0) }

    let anotherUpdateLoadRequest = self.policyForNavigationActionProperty.signal.ignoreNil()
      .filter { $0.navigationType == .LinkActivated && Router.decodeUpdate(request: $0.request) != nil }
      .map { AppEnvironment.current.apiService.preparedRequest(forRequest: $0.request) }

    self.webViewLoadRequest = Signal.merge(
      initialUpdateLoadRequest,
      anotherUpdateLoadRequest
    )

    let anotherUpdate = anotherUpdateLoadRequest
      .map { Router.decodeUpdate(request: $0) }
      .ignoreNil()
      .switchMap { updateRoute in
        return AppEnvironment.current.apiService
          .fetchUpdate(updateId: updateRoute.updateId, projectParam: updateRoute.projectParam)
          .demoteErrors()
    }

    let currentUpdate = Signal.merge(initialUpdate, anotherUpdate)

    self.title = combineLatest(currentUpdate, self.viewDidLoadProperty.signal.take(1))
      .map(first)
      .map { Strings.activity_project_update_update_count(update_count: Format.wholeNumber($0.sequence)) }

    self.policyDecisionProperty <~ self.policyForNavigationActionProperty.signal.ignoreNil()
      .map { $0.navigationType == .Other ? .Allow : .Cancel }

    let commentsRequest = self.policyForNavigationActionProperty.signal.ignoreNil()
      .filter { $0.navigationType == .LinkActivated }
      .filter { Router.decodeUpdateComments(request: $0.request) != nil }

    self.goToComments = currentUpdate
      .takeWhen(commentsRequest)

    let projectRoute = self.policyForNavigationActionProperty.signal.ignoreNil()
      .filter { $0.navigationType == .LinkActivated }
      .map { Router.decodeProject(request: $0.request) }
      .ignoreNil()

    self.goToProject = self.projectProperty.signal.ignoreNil()
      .takePairWhen(projectRoute)
      .switchMap { (project, projectRoute) -> SignalProducer<(Project, RefTag?), NoError> in

        let producer: SignalProducer<Project, NoError>

        if projectRoute.projectParam == .id(project.id) ||
          projectRoute.projectParam == .slug(project.slug) {

          producer = SignalProducer(value: project)
        } else {
          producer = AppEnvironment.current.apiService.fetchProject(param: projectRoute.projectParam)
            .demoteErrors()
        }

        return producer.map { ($0, projectRoute.refTag) }
      }
  }
  // swiftlint:enable function_body_length

  private let updateProperty = MutableProperty<Update?>(nil)
  private let projectProperty = MutableProperty<Project?>(nil)
  internal func configureWith(project project: Project, update: Update) {
    self.updateProperty.value = update
    self.projectProperty.value = project
  }

  private let policyForNavigationActionProperty = MutableProperty<WKNavigationActionProtocol?>(nil)
  private let policyDecisionProperty = MutableProperty(WKNavigationActionPolicy.Allow)
  internal func decidePolicyFor(navigationAction navigationAction: WKNavigationActionProtocol)
    -> WKNavigationActionPolicy {
      self.policyForNavigationActionProperty.value = navigationAction
      return self.policyDecisionProperty.value
  }

  private let viewDidLoadProperty = MutableProperty()
  internal func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  internal let goToComments: Signal<Update, NoError>
  internal let goToProject: Signal<(Project, RefTag?), NoError>
  internal let title: Signal<String, NoError>
  internal let webViewLoadRequest: Signal<NSURLRequest, NoError>

  internal var inputs: UpdateViewModelInputs { return self }
  internal var outputs: UpdateViewModelOutputs { return self }
}