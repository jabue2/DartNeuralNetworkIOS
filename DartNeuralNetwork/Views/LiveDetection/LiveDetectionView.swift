import SwiftUI
import AVFoundation

struct LiveDetectionView: UIViewControllerRepresentable {
    var controller: LiveDartDetectionController
    @Binding var scoreText: String

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        
        // Create a container view for the live preview.
        let previewHeight: CGFloat = 450  // adjust height as needed
        let previewView = UIView(frame: CGRect(x: 0, y: 0, width: vc.view.bounds.width, height: previewHeight))
        previewView.backgroundColor = .black
        previewView.autoresizingMask = [.flexibleWidth]
        vc.view.addSubview(previewView)
        
        // Create a label for the score, placed right below the preview.
        let scoreLabel = UILabel(frame: CGRect(x: 0, y: previewHeight, width: vc.view.bounds.width, height: 50))
        scoreLabel.textAlignment = .center
        scoreLabel.font = UIFont.boldSystemFont(ofSize: 20)
        scoreLabel.textColor = .white
        scoreLabel.backgroundColor = .darkGray
        scoreLabel.tag = 101  // tag for later lookup
        vc.view.addSubview(scoreLabel)
        
        // Start the live capture session inside the preview.
        controller.startSession(in: previewView)
        
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let scoreLabel = uiViewController.view.viewWithTag(101) as? UILabel {
            scoreLabel.text = scoreText
        }
    }
}
