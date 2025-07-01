import SwiftUI

struct PhotoModeView: View {
    @State private var inputImage: UIImage?
    @State private var processedImage: UIImage?
    @State private var showingImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .camera
    @State private var processor: DartboardProcessing? = DartboardProcessing()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 30) {
                    Text("Photo Mode")
                        .font(.headline)
                    
                    if let image = processedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .border(Color.gray, width: 1)
                            .padding()
                        
                        Button(action: {
                            if let image = processedImage {
                                processor?.runPipeline(on: image) { pipelineImage in
                                    DispatchQueue.main.async {
                                        self.processedImage = pipelineImage
                                    }
                                }
                            }
                        }) {
                            Text("Run Full Pipeline")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .padding(.horizontal)
                    } else {
                        Text("No Photo Selected")
                            .foregroundColor(.gray)
                    }
                    
                    HStack(spacing: 16) {
                        Button(action: {
                            imagePickerSourceType = .camera
                            self.showingImagePicker = true
                        }) {
                            Text("Take Photo")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        
                        Button(action: {
                            imagePickerSourceType = .photoLibrary
                            self.showingImagePicker = true
                        }) {
                            Text("Choose Photo")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding()
            }
            .navigationBarTitle("Photo Mode", displayMode: .inline)
            .sheet(isPresented: $showingImagePicker, onDismiss: processImage) {
                ImagePicker(image: self.$inputImage, sourceType: imagePickerSourceType)
            }
        }
    }
    
    func processImage() {
        guard let inputImage = inputImage else { return }
        processor?.detectDartboard(in: inputImage) { croppedImage in
            DispatchQueue.main.async {
                self.processedImage = croppedImage
            }
        }
    }
}

struct PhotoModeView_Previews: PreviewProvider {
    static var previews: some View {
        PhotoModeView()
    }
}
